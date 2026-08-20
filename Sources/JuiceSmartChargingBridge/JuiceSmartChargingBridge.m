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

static JSCChargeLimitOptions JSCChargeLimitOption(NSInteger chargeLimit) {
    switch (chargeLimit) {
        case 80: return JSCChargeLimitOption80;
        case 85: return JSCChargeLimitOption85;
        case 90: return JSCChargeLimitOption90;
        case 95: return JSCChargeLimitOption95;
        case 100: return JSCChargeLimitOption100;
        default: return JSCChargeLimitOptionNone;
    }
}

JSCChargeLimitOptions JSCResolveAvailableChargeLimits(NSArray *rawLimits) {
    if (![rawLimits isKindOfClass:[NSArray class]]) {
        return JSCChargeLimitOptionNone;
    }

    JSCChargeLimitOptions options = JSCChargeLimitOptionNone;
    for (id rawValue in rawLimits) {
        if (![rawValue isKindOfClass:[NSNumber class]]) {
            return JSCChargeLimitOptionNone;
        }
        double numericValue = [rawValue doubleValue];
        NSInteger integerValue = [rawValue integerValue];
        JSCChargeLimitOptions option = JSCChargeLimitOption(integerValue);
        if (numericValue != (double)integerValue
            || option == JSCChargeLimitOptionNone
            || (options & option) != 0) {
            return JSCChargeLimitOptionNone;
        }
        options |= option;
    }
    return options;
}

JSCChargeLimitState JSCResolveChargeLimitState(
    NSUInteger rawState,
    NSInteger currentLimit
) {
    switch (rawState) {
        case JSCChargeLimitStateDisabled:
            return currentLimit == 100
                ? JSCChargeLimitStateDisabled
                : JSCChargeLimitStateUnknown;
        case JSCChargeLimitStateEnabled:
            return currentLimit < 100
                    && JSCChargeLimitOption(currentLimit)
                        != JSCChargeLimitOptionNone
                ? JSCChargeLimitStateEnabled
                : JSCChargeLimitStateUnknown;
        case JSCChargeLimitStateTemporarilyDisabled:
            return currentLimit == 100
                ? JSCChargeLimitStateTemporarilyDisabled
                : JSCChargeLimitStateUnknown;
        default:
            return JSCChargeLimitStateUnknown;
    }
}

JSCOptimizedChargingState JSCResolveOptimizedChargingState(
    NSUInteger rawState
) {
    switch (rawState) {
        case JSCOptimizedChargingStateDisabled:
            return JSCOptimizedChargingStateDisabled;
        case JSCOptimizedChargingStateEnabled:
            return JSCOptimizedChargingStateEnabled;
        case JSCOptimizedChargingStateChargingToFull:
            return JSCOptimizedChargingStateChargingToFull;
        case JSCOptimizedChargingStateTemporarilyDisabled:
            return JSCOptimizedChargingStateTemporarilyDisabled;
        default:
            return JSCOptimizedChargingStateUnknown;
    }
}

static BOOL JSCOptimizedChargingSetterIsAvailable(
    id client,
    NSString *selectorName
) {
    SEL selector = NSSelectorFromString(selectorName);
    const char *arguments[] = { "^@" }; // NSError * __autoreleasing *
    return [client respondsToSelector:selector]
        && JSCMethodMatches(
            [client class],
            selector,
            @encode(BOOL),
            arguments,
            1);
}

static BOOL JSCOptimizedChargingSettersAreAvailable(id client) {
    return JSCOptimizedChargingSetterIsAvailable(
            client,
            @"enableSmartCharging:")
        && JSCOptimizedChargingSetterIsAvailable(
            client,
            @"disableSmartCharging:")
        && JSCOptimizedChargingSetterIsAvailable(
            client,
            @"temporarilyDisableSmartCharging:");
}

static BOOL JSCReadOptimizedChargingConfiguration(
    id client,
    BOOL *supported,
    JSCOptimizedChargingState *state,
    NSError **error
) {
    // PowerUISmartChargeClient's no-error support getter silently returns NO
    // when its XPC lookup fails. System Settings instead uses the utility
    // class's local hardware check, leaving the error-bearing state call below
    // to distinguish an unavailable service from unsupported hardware.
    Class utilitiesClass = NSClassFromString(@"PowerUISmartChargeUtilities");
    SEL supportSelector = NSSelectorFromString(@"isOBCSupported");
    Class utilitiesMetaClass = utilitiesClass == Nil
        ? Nil
        : object_getClass(utilitiesClass);
    if (utilitiesClass == Nil
        || ![utilitiesClass respondsToSelector:supportSelector]
        || !JSCMethodMatches(
            utilitiesMetaClass,
            supportSelector,
            @encode(BOOL),
            NULL,
            0)) {
        if (error != NULL) {
            *error = JSCError(
                JSCErrorUnavailable,
                @"This macOS version does not expose Optimized Battery Charging to Juice."
            );
        }
        return NO;
    }

    typedef BOOL (*SupportFunction)(id, SEL);
    BOOL isSupported = ((SupportFunction)objc_msgSend)(
        utilitiesClass,
        supportSelector
    );
    if (!isSupported) {
        if (supported != NULL) {
            *supported = NO;
        }
        return YES;
    }

    SEL stateSelector = NSSelectorFromString(
        @"isSmartChargingCurrentlyEnabled:"
    );
    const char *errorArgument[] = { "^@" };
    if (![client respondsToSelector:stateSelector]
        || !JSCMethodMatches(
            [client class],
            stateSelector,
            @encode(NSUInteger),
            errorArgument,
            1)) {
        if (error != NULL) {
            *error = JSCError(
                JSCErrorUnavailable,
                @"This macOS version does not expose the Optimized Battery Charging state."
            );
        }
        return NO;
    }

    NSError *stateError = nil;
    typedef NSUInteger (*StateFunction)(id, SEL, NSError **);
    NSUInteger rawState = ((StateFunction)objc_msgSend)(
        client,
        stateSelector,
        &stateError
    );
    JSCOptimizedChargingState resolvedState =
        JSCResolveOptimizedChargingState(rawState);
    if (stateError != nil
        || resolvedState == JSCOptimizedChargingStateUnknown) {
        if (error != NULL) {
            *error = stateError ?: JSCError(
                JSCErrorCallFailed,
                @"macOS returned an unsupported Optimized Battery Charging state."
            );
        }
        return NO;
    }

    // This is an editable Settings surface, so drift in any action ABI makes
    // the whole control unavailable rather than leaving an enabled switch that
    // can never complete one of its advertised choices.
    if (!JSCOptimizedChargingSettersAreAvailable(client)) {
        if (error != NULL) {
            *error = JSCError(
                JSCErrorUnavailable,
                @"This macOS version cannot change Optimized Battery Charging from Juice."
            );
        }
        return NO;
    }

    if (supported != NULL) {
        *supported = YES;
    }
    if (state != NULL) {
        *state = resolvedState;
    }
    return YES;
}

static BOOL JSCChargeLimitSetterIsAvailable(id client) {
    SEL selector = NSSelectorFromString(@"setMCLLimit:error:");
    const char *arguments[] = {
        @encode(unsigned char),
        "^@", // NSError * __autoreleasing *
    };
    return [client respondsToSelector:selector]
        && JSCMethodMatches(
            [client class],
            selector,
            @encode(BOOL),
            arguments,
            2);
}

static BOOL JSCReadChargeLimitConfiguration(
    id client,
    BOOL *supported,
    NSInteger *currentLimit,
    JSCChargeLimitOptions *availableLimits,
    JSCChargeLimitState *state,
    NSError **error
) {
    SEL supportSelector = NSSelectorFromString(@"isMCLSupported");
    if (![client respondsToSelector:supportSelector]
        || !JSCMethodMatches(
            [client class],
            supportSelector,
            @encode(BOOL),
            NULL,
            0)) {
        if (error != NULL) {
            *error = JSCError(
                JSCErrorUnavailable,
                @"This macOS version does not expose Charge Limit to Juice."
            );
        }
        return NO;
    }

    typedef BOOL (*SupportFunction)(id, SEL);
    BOOL isSupported = ((SupportFunction)objc_msgSend)(
        client,
        supportSelector
    );
    if (supported != NULL) {
        *supported = isSupported;
    }
    if (!isSupported) {
        return YES;
    }

    SEL availableSelector = NSSelectorFromString(
        @"availableChargeLimitsWithError:"
    );
    const char *errorArgument[] = { "^@" }; // NSError * __autoreleasing *
    if (![client respondsToSelector:availableSelector]
        || !JSCMethodMatches(
            [client class],
            availableSelector,
            @encode(id),
            errorArgument,
            1)) {
        if (error != NULL) {
            *error = JSCError(
                JSCErrorUnavailable,
                @"This macOS version does not expose Charge Limit choices."
            );
        }
        return NO;
    }

    NSError *availableError = nil;
    typedef id (*AvailableFunction)(id, SEL, NSError **);
    id rawAvailable = ((AvailableFunction)objc_msgSend)(
        client,
        availableSelector,
        &availableError
    );
    if (availableError != nil
        || ![rawAvailable isKindOfClass:[NSArray class]]) {
        if (error != NULL) {
            *error = availableError ?: JSCError(
                JSCErrorCallFailed,
                @"macOS did not return its available Charge Limit choices."
            );
        }
        return NO;
    }

    JSCChargeLimitOptions options =
        JSCResolveAvailableChargeLimits((NSArray *)rawAvailable);
    if (options == JSCChargeLimitOptionNone) {
        if (error != NULL) {
            *error = JSCError(
                JSCErrorCallFailed,
                @"macOS returned no supported Charge Limit choices."
            );
        }
        return NO;
    }

    SEL currentSelector = NSSelectorFromString(@"getMCLLimitWithError:");
    if (![client respondsToSelector:currentSelector]
        || !JSCMethodMatches(
            [client class],
            currentSelector,
            @encode(unsigned char),
            errorArgument,
            1)) {
        if (error != NULL) {
            *error = JSCError(
                JSCErrorUnavailable,
                @"This macOS version does not expose the configured Charge Limit."
            );
        }
        return NO;
    }

    NSError *currentError = nil;
    typedef unsigned char (*CurrentFunction)(id, SEL, NSError **);
    unsigned char rawCurrent = ((CurrentFunction)objc_msgSend)(
        client,
        currentSelector,
        &currentError
    );
    JSCChargeLimitOptions currentOption = JSCChargeLimitOption(rawCurrent);
    if (currentError != nil
        || currentOption == JSCChargeLimitOptionNone
        || (options & currentOption) == 0) {
        if (error != NULL) {
            *error = currentError ?: JSCError(
                JSCErrorCallFailed,
                @"macOS returned an unsupported configured Charge Limit."
            );
        }
        return NO;
    }

    SEL stateSelector = NSSelectorFromString(@"isMCLCurrentlyEnabled:");
    if (![client respondsToSelector:stateSelector]
        || !JSCMethodMatches(
            [client class],
            stateSelector,
            @encode(NSUInteger),
            errorArgument,
            1)) {
        if (error != NULL) {
            *error = JSCError(
                JSCErrorUnavailable,
                @"This macOS version does not expose the Charge Limit state."
            );
        }
        return NO;
    }

    NSError *stateError = nil;
    typedef NSUInteger (*StateFunction)(id, SEL, NSError **);
    NSUInteger rawState = ((StateFunction)objc_msgSend)(
        client,
        stateSelector,
        &stateError
    );
    JSCChargeLimitState resolvedState =
        JSCResolveChargeLimitState(rawState, rawCurrent);
    if (stateError != nil
        || resolvedState == JSCChargeLimitStateUnknown) {
        if (error != NULL) {
            *error = stateError ?: JSCError(
                JSCErrorCallFailed,
                @"macOS returned an unsupported Charge Limit state."
            );
        }
        return NO;
    }
    if (!JSCChargeLimitSetterIsAvailable(client)) {
        if (error != NULL) {
            *error = JSCError(
                JSCErrorUnavailable,
                @"This macOS version cannot change Charge Limit from Juice."
            );
        }
        return NO;
    }
    if (state != NULL) {
        *state = resolvedState;
    }
    if (currentLimit != NULL) {
        *currentLimit = rawCurrent;
    }
    if (availableLimits != NULL) {
        *availableLimits = options;
    }
    return YES;
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

BOOL JSCChargeToFull(
    JSCChargeHoldKind *actedKind,
    NSInteger *actedChargeLimit,
    NSError **error
) {
    if (actedKind != NULL) {
        *actedKind = JSCChargeHoldKindNone;
    }
    if (actedChargeLimit != NULL) {
        *actedChargeLimit = 100;
    }

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
    NSInteger chargeLimit = 100;
    if (!JSCReadResolvedStatus(client, &kind, &chargeLimit, error)) {
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
    if (!succeeded || callError != nil) {
        if (error != NULL) {
            *error = callError ?: JSCError(
                JSCErrorCallFailed,
                @"macOS did not start charging to full."
            );
        }
        return NO;
    }
    if (actedKind != NULL) {
        *actedKind = kind;
    }
    if (actedChargeLimit != NULL) {
        *actedChargeLimit = chargeLimit;
    }
    return YES;
}

BOOL JSCCopyChargeLimitConfiguration(
    BOOL *supported,
    NSInteger *currentLimit,
    JSCChargeLimitOptions *availableLimits,
    JSCChargeLimitState *state,
    NSError **error
) {
    if (supported != NULL) {
        *supported = NO;
    }
    if (currentLimit != NULL) {
        *currentLimit = 100;
    }
    if (availableLimits != NULL) {
        *availableLimits = JSCChargeLimitOptionNone;
    }
    if (state != NULL) {
        *state = JSCChargeLimitStateUnknown;
    }

    NSError *clientError = nil;
    id client = JSCNewClient(&clientError);
    if (client == nil) {
        if (error != NULL) {
            *error = clientError;
        }
        return NO;
    }

    return JSCReadChargeLimitConfiguration(
        client,
        supported,
        currentLimit,
        availableLimits,
        state,
        error
    );
}

BOOL JSCSetChargeLimit(NSInteger chargeLimit, NSError **error) {
    JSCChargeLimitOptions requestedOption = JSCChargeLimitOption(chargeLimit);
    if (requestedOption == JSCChargeLimitOptionNone) {
        if (error != NULL) {
            *error = JSCError(
                JSCErrorUnavailable,
                @"That Charge Limit is not supported."
            );
        }
        return NO;
    }

    NSError *clientError = nil;
    id client = JSCNewClient(&clientError);
    if (client == nil) {
        if (error != NULL) {
            *error = clientError;
        }
        return NO;
    }

    BOOL supported = NO;
    NSInteger currentLimit = 100;
    JSCChargeLimitOptions availableLimits = JSCChargeLimitOptionNone;
    JSCChargeLimitState state = JSCChargeLimitStateUnknown;
    if (!JSCReadChargeLimitConfiguration(
            client,
            &supported,
            &currentLimit,
            &availableLimits,
            &state,
            error)) {
        return NO;
    }
    if (!supported || (availableLimits & requestedOption) == 0) {
        if (error != NULL) {
            *error = JSCError(
                JSCErrorUnavailable,
                @"That Charge Limit is not available on this Mac."
            );
        }
        return NO;
    }
    if (state != JSCChargeLimitStateTemporarilyDisabled
        && currentLimit == chargeLimit) {
        return YES;
    }

    SEL selector = NSSelectorFromString(@"setMCLLimit:error:");
    if (!JSCChargeLimitSetterIsAvailable(client)) {
        if (error != NULL) {
            *error = JSCError(
                JSCErrorUnavailable,
                @"This macOS version cannot change Charge Limit from Juice."
            );
        }
        return NO;
    }

    NSError *callError = nil;
    typedef BOOL (*Function)(id, SEL, unsigned char, NSError **);
    BOOL succeeded = ((Function)objc_msgSend)(
        client,
        selector,
        (unsigned char)chargeLimit,
        &callError
    );
    if (!succeeded || callError != nil) {
        if (error != NULL) {
            *error = callError ?: JSCError(
                JSCErrorCallFailed,
                @"macOS did not apply the new Charge Limit."
            );
        }
        return NO;
    }
    return YES;
}

BOOL JSCCopyOptimizedChargingConfiguration(
    BOOL *supported,
    JSCOptimizedChargingState *state,
    NSError **error
) {
    if (supported != NULL) {
        *supported = NO;
    }
    if (state != NULL) {
        *state = JSCOptimizedChargingStateUnknown;
    }

    NSError *clientError = nil;
    id client = JSCNewClient(&clientError);
    if (client == nil) {
        if (error != NULL) {
            *error = clientError;
        }
        return NO;
    }

    return JSCReadOptimizedChargingConfiguration(
        client,
        supported,
        state,
        error
    );
}

typedef NS_ENUM(NSInteger, JSCOptimizedChargingAction) {
    JSCOptimizedChargingActionEnable,
    JSCOptimizedChargingActionDisable,
    JSCOptimizedChargingActionTemporarilyDisable,
};

static BOOL JSCPerformOptimizedChargingAction(
    JSCOptimizedChargingAction action,
    NSError **error
) {
    NSError *clientError = nil;
    id client = JSCNewClient(&clientError);
    if (client == nil) {
        if (error != NULL) {
            *error = clientError;
        }
        return NO;
    }

    BOOL supported = NO;
    JSCOptimizedChargingState state = JSCOptimizedChargingStateUnknown;
    if (!JSCReadOptimizedChargingConfiguration(
            client,
            &supported,
            &state,
            error)) {
        return NO;
    }
    if (!supported) {
        if (error != NULL) {
            *error = JSCError(
                JSCErrorUnavailable,
                @"Optimized Battery Charging is not available on this Mac."
            );
        }
        return NO;
    }

    NSString *selectorName;
    switch (action) {
        case JSCOptimizedChargingActionEnable:
            if (state == JSCOptimizedChargingStateEnabled) {
                return YES;
            }
            selectorName = @"enableSmartCharging:";
            break;
        case JSCOptimizedChargingActionDisable:
            if (state == JSCOptimizedChargingStateDisabled) {
                return YES;
            }
            selectorName = @"disableSmartCharging:";
            break;
        case JSCOptimizedChargingActionTemporarilyDisable:
            if (state == JSCOptimizedChargingStateTemporarilyDisabled) {
                return YES;
            }
            if (state != JSCOptimizedChargingStateEnabled) {
                if (error != NULL) {
                    *error = JSCError(
                        JSCErrorUnavailable,
                        @"Optimized Battery Charging cannot be turned off temporarily in its current state."
                    );
                }
                return NO;
            }
            selectorName = @"temporarilyDisableSmartCharging:";
            break;
    }

    if (!JSCOptimizedChargingSetterIsAvailable(client, selectorName)) {
        if (error != NULL) {
            *error = JSCError(
                JSCErrorUnavailable,
                @"This macOS version cannot change Optimized Battery Charging from Juice."
            );
        }
        return NO;
    }

    SEL selector = NSSelectorFromString(selectorName);
    NSError *callError = nil;
    typedef BOOL (*Function)(id, SEL, NSError **);
    BOOL succeeded = ((Function)objc_msgSend)(
        client,
        selector,
        &callError
    );
    if (!succeeded || callError != nil) {
        if (error != NULL) {
            *error = callError ?: JSCError(
                JSCErrorCallFailed,
                @"macOS did not change Optimized Battery Charging."
            );
        }
        return NO;
    }
    return YES;
}

BOOL JSCSetOptimizedChargingEnabled(BOOL enabled, NSError **error) {
    return JSCPerformOptimizedChargingAction(
        enabled
            ? JSCOptimizedChargingActionEnable
            : JSCOptimizedChargingActionDisable,
        error
    );
}

BOOL JSCTemporarilyDisableOptimizedCharging(NSError **error) {
    return JSCPerformOptimizedChargingAction(
        JSCOptimizedChargingActionTemporarilyDisable,
        error
    );
}
