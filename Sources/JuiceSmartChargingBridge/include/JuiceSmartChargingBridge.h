#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The two actionable states exposed by macOS's smart-charging service.
typedef NS_ENUM(NSInteger, JSCChargeHoldKind) {
    JSCChargeHoldKindNone = 0,
    JSCChargeHoldKindOptimized = 1,
    JSCChargeHoldKindLimit = 2,
};

/// Pure interpretation of PowerUI's current raw UI state. This performs no
/// system I/O and exists separately so unknown macOS revisions can be covered
/// by fail-closed unit tests.
FOUNDATION_EXPORT JSCChargeHoldKind JSCResolveChargeHoldKind(
    NSUInteger rawState,
    BOOL chargingOverrideAllowed
);

/// Reads the same smart-charging UI state used by Control Center.
///
/// A successful call can still return ``JSCChargeHoldKindNone``. That means
/// macOS answered authoritatively but there is no Charge to Full command to
/// show. Unknown interface/state revisions also fail closed to `None`.
FOUNDATION_EXPORT BOOL JSCCopyChargeHoldStatus(
    JSCChargeHoldKind *kind,
    NSInteger *chargeLimit,
    NSError * _Nullable * _Nullable error
);

/// Re-reads the current hold and requests its matching temporary override.
/// The read and selector choice happen together so a stale UI snapshot cannot
/// choose the wrong operation.
FOUNDATION_EXPORT BOOL JSCChargeToFull(
    NSError * _Nullable * _Nullable error
);

NS_ASSUME_NONNULL_END
