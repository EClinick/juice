#import "JuiceSmartChargingBridge.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>

static NSString * const JSCErrorDomain = @"com.eclinick.juice.smart-charging";

typedef NS_ENUM(NSInteger, JSCErrorCode) {
    JSCErrorUnavailable = 1,
    JSCErrorCallFailed = 2,
};

static NSError *JSCError(JSCErrorCode code, NSString *message) {
    return [NSError errorWithDomain:JSCErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL JSCMethodMatches(
    Class clientClass,
    SEL selector,
    const char *returnType,
    const char * const *argumentTypes,
    unsigned int argumentCount
) {
    Method method = class_getInstanceMethod(clientClass, selector);
    if (method == NULL || method_getNumberOfArguments(method) != argumentCount + 2) {
        return NO;
    }

    char *actualReturnType = method_copyReturnType(method);
    BOOL matches = actualReturnType != NULL
        && strcmp(actualReturnType, returnType) == 0;
    free(actualReturnType);

    for (unsigned int index = 0; matches && index < argumentCount; index++) {
        char *actualArgumentType = method_copyArgumentType(method, index + 2);
        matches = actualArgumentType != NULL
            && strcmp(actualArgumentType, argumentTypes[index]) == 0;
        free(actualArgumentType);
    }
    return matches;
}

static Class JSCClientClass(NSError **error) {
    static Class clientClass;
    static NSError *loadError;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *path = "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI";
        if (dlopen(path, RTLD_LAZY | RTLD_LOCAL) == NULL) {
            const char *detail = dlerror();
            NSString *message = detail == NULL
                ? @"macOS smart charging is unavailable."
                : [NSString stringWithUTF8String:detail];
            loadError = JSCError(JSCErrorUnavailable, message);
            return;
        }
        clientClass = NSClassFromString(@"PowerUISmartChargeClient");
        if (clientClass == Nil) {
            loadError = JSCError(
                JSCErrorUnavailable,
                @"macOS smart charging is unavailable."
            );
        }
    });
    if (clientClass == Nil && error != NULL) {
        *error = loadError;
    }
    return clientClass;
}

static id JSCNewClient(NSError **error) {
    Class clientClass = JSCClientClass(error);
    if (clientClass == Nil) {
        return nil;
    }

    SEL initializer = NSSelectorFromString(@"initWithClientName:");
    const char *initializerArguments[] = { @encode(id) };
    if (![clientClass instancesRespondToSelector:initializer]
        || !JSCMethodMatches(
            clientClass,
            initializer,
            @encode(id),
            initializerArguments,
            1)) {
        if (error != NULL) {
            *error = JSCError(
                JSCErrorUnavailable,
                @"This macOS version does not expose smart charging to Juice."
            );
        }
        return nil;
    }

    id allocated = [clientClass alloc];
    NSString *clientName = NSBundle.mainBundle.bundleIdentifier ?: @"Juice";
    typedef id NS_RETURNS_RETAINED (*Initializer)(
        id NS_RELEASES_ARGUMENT, SEL, id
    );
    return ((Initializer)objc_msgSend)(
        allocated,
        initializer,
        clientName
    );
}

static BOOL JSCCallUIState(
    id client,
    NSUInteger *state,
    NSUInteger *chargeLimit,
    BOOL *overrideAllowed,
    NSError **error
) {
    SEL selector = NSSelectorFromString(
        @"smartChargingUIState:chargeLimit:chargingOverrideAllowed:withError:"
    );
    const char *arguments[] = {
        @encode(NSUInteger *),
        @encode(NSUInteger *),
        @encode(BOOL *),
        "^@", // NSError * __autoreleasing *
    };
    if (![client respondsToSelector:selector]
        || !JSCMethodMatches(
            [client class],
            selector,
            @encode(BOOL),
            arguments,
            4)) {
        if (error != NULL) {
            *error = JSCError(
                JSCErrorUnavailable,
                @"This macOS version does not expose smart-charging UI state."
            );
        }
        return NO;
    }

    typedef BOOL (*Function)(
        id, SEL, NSUInteger *, NSUInteger *, BOOL *, NSError **
    );
    return ((Function)objc_msgSend)(
        client,
        selector,
        state,
        chargeLimit,
        overrideAllowed,
        error
    );
}

static NSInteger JSCManualChargeLimit(id client, NSInteger fallback) {
    SEL selector = NSSelectorFromString(@"getMCLLimitWithError:");
    const char *arguments[] = { "^@" }; // NSError * __autoreleasing *
    if (![client respondsToSelector:selector]
        || !JSCMethodMatches(
            [client class],
            selector,
            @encode(unsigned char),
            arguments,
            1)) {
        return fallback;
    }

    NSError *error = nil;
    typedef unsigned char (*Function)(id, SEL, NSError **);
    unsigned char value = ((Function)objc_msgSend)(client, selector, &error);
    if (error != nil || value == 0 || value > 100) {
        return fallback;
    }
    return value;
}

JSCChargeHoldKind JSCResolveChargeHoldKind(
    NSUInteger rawState,
    BOOL chargingOverrideAllowed
) {
    // These are the UI-state families consumed by Control Center in macOS 26:
    // 6, 7, 8, 10, 11, and 12 are optimized-charging hold variants. States
    // 14, 15, and 16 are configured manual-limit variants that Control Center
    // resolves as charged-to-limit. State 13 is charging-to-limit, so it is not
    // actionable. Unknown values are intentionally hidden rather than inferred
    // from generic battery flags.
    const NSUInteger optimizedHoldStates = 0x1DC0;
    BOOL optimizedHold = rawState < (sizeof(NSUInteger) * 8)
        && ((optimizedHoldStates & (((NSUInteger)1) << rawState)) != 0);

    if (optimizedHold && chargingOverrideAllowed) {
        return JSCChargeHoldKindOptimized;
    }
    if (rawState >= 14 && rawState <= 16) {
        return JSCChargeHoldKindLimit;
    }
    return JSCChargeHoldKindNone;
}

static BOOL JSCReadResolvedStatus(
    id client,
    JSCChargeHoldKind *kind,
    NSInteger *chargeLimit,
    NSError **error
) {
    NSUInteger rawState = 0;
    NSUInteger rawLimit = 100;
    BOOL overrideAllowed = NO;
    NSError *callError = nil;
    BOOL succeeded = JSCCallUIState(
        client,
        &rawState,
        &rawLimit,
        &overrideAllowed,
        &callError
    );
    if (!succeeded) {
        if (error != NULL) {
            *error = callError ?: JSCError(
                JSCErrorCallFailed,
                @"macOS did not return smart-charging state."
            );
        }
        return NO;
    }

    JSCChargeHoldKind resolvedKind = JSCResolveChargeHoldKind(
        rawState,
        overrideAllowed
    );
    NSInteger resolvedLimit = rawLimit > 0 && rawLimit <= 100
        ? (NSInteger)rawLimit
        : 100;
    if (resolvedKind == JSCChargeHoldKindLimit) {
        NSInteger manualLimit = JSCManualChargeLimit(client, resolvedLimit);
        // State 13 without a readable configured limit is not enough to put a
        // percentage in front of the user. Fail closed instead of inventing it.
        if (manualLimit > 0 && manualLimit < 100) {
            resolvedLimit = manualLimit;
        } else {
            resolvedKind = JSCChargeHoldKindNone;
        }
    }

    if (kind != NULL) {
        *kind = resolvedKind;
    }
    if (chargeLimit != NULL) {
        *chargeLimit = resolvedLimit;
    }
    return YES;
}

BOOL JSCCopyChargeHoldStatus(
    JSCChargeHoldKind *kind,
    NSInteger *chargeLimit,
    NSError **error
) {
    if (kind != NULL) {
        *kind = JSCChargeHoldKindNone;
    }
    if (chargeLimit != NULL) {
        *chargeLimit = 100;
    }

    NSError *clientError = nil;
    id client = JSCNewClient(&clientError);
    if (client == nil) {
        if (error != NULL) {
            *error = clientError;
        }
        return NO;
    }

    return JSCReadResolvedStatus(
        client,
        kind,
        chargeLimit,
        error
    );
}

BOOL JSCChargeToFull(NSError **error) {
    NSError *clientError = nil;
    id client = JSCNewClient(&clientError);
    if (client == nil) {
        if (error != NULL) {
            *error = clientError;
        }
        return NO;
    }

    // The popover may have been open while macOS changed charging modes. Read
    // again at the point of action and select the operation from that current
    // authoritative state instead of accepting a kind captured by the UI.
    JSCChargeHoldKind kind = JSCChargeHoldKindNone;
    if (!JSCReadResolvedStatus(client, &kind, NULL, error)) {
        return NO;
    }

    SEL selector;
    switch (kind) {
        case JSCChargeHoldKindOptimized:
            selector = NSSelectorFromString(@"temporarilyEnableCharging:");
            break;
        case JSCChargeHoldKindLimit:
            selector = NSSelectorFromString(@"temporarilyDisableMCL:");
            break;
        case JSCChargeHoldKindNone:
            if (error != NULL) {
                *error = JSCError(
                    JSCErrorUnavailable,
                    @"There is no charging hold to override."
                );
            }
            return NO;
    }

    const char *arguments[] = { "^@" }; // NSError * __autoreleasing *
    if (![client respondsToSelector:selector]
        || !JSCMethodMatches(
            [client class],
            selector,
            @encode(BOOL),
            arguments,
            1)) {
        if (error != NULL) {
            *error = JSCError(
                JSCErrorUnavailable,
                @"This macOS version cannot temporarily override charging."
            );
        }
        return NO;
    }

    NSError *callError = nil;
    typedef BOOL (*Function)(id, SEL, NSError **);
    BOOL succeeded = ((Function)objc_msgSend)(client, selector, &callError);
    if (!succeeded && error != NULL) {
        *error = callError ?: JSCError(
            JSCErrorCallFailed,
            @"macOS did not start charging to full."
        );
    }
    return succeeded;
}
