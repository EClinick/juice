#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The two actionable states exposed by macOS's smart-charging service.
typedef NS_ENUM(NSInteger, JSCChargeHoldKind) {
    JSCChargeHoldKindNone = 0,
    JSCChargeHoldKindOptimized = 1,
    JSCChargeHoldKindLimit = 2,
};

/// Charge-limit choices currently exposed by macOS. A bit mask keeps the
/// Objective-C bridge independent of Swift collection ownership while still
/// allowing future macOS revisions to remove choices safely.
typedef NS_OPTIONS(NSUInteger, JSCChargeLimitOptions) {
    JSCChargeLimitOptionNone = 0,
    JSCChargeLimitOption80 = 1 << 0,
    JSCChargeLimitOption85 = 1 << 1,
    JSCChargeLimitOption90 = 1 << 2,
    JSCChargeLimitOption95 = 1 << 3,
    JSCChargeLimitOption100 = 1 << 4,
};

/// PowerUI distinguishes the normal persistent state from a one-time
/// Charge-to-Full override. In the latter state, its public-looking limit
/// getter reports the temporary target rather than the saved persistent limit.
typedef NS_ENUM(NSInteger, JSCChargeLimitState) {
    JSCChargeLimitStateUnknown = -1,
    JSCChargeLimitStateDisabled = 0,
    JSCChargeLimitStateEnabled = 1,
    JSCChargeLimitStateTemporarilyDisabled = 3,
};

/// The states returned by PowerUI for Optimized Battery Charging. The
/// temporary state is distinct from the persistent off preference: macOS uses
/// it for one-time charging overrides such as "Turn Off Until Tomorrow."
typedef NS_ENUM(NSInteger, JSCOptimizedChargingState) {
    JSCOptimizedChargingStateUnknown = -1,
    JSCOptimizedChargingStateDisabled = 0,
    JSCOptimizedChargingStateEnabled = 1,
    JSCOptimizedChargingStateChargingToFull = 2,
    JSCOptimizedChargingStateTemporarilyDisabled = 3,
};

/// Pure validation helpers used by the dynamic bridge. They perform no system
/// I/O so unexpected future payloads and state/value pairings can be covered by
/// fail-closed unit tests.
FOUNDATION_EXPORT JSCChargeLimitOptions JSCResolveAvailableChargeLimits(
    NSArray *rawLimits
);
FOUNDATION_EXPORT JSCChargeLimitState JSCResolveChargeLimitState(
    NSUInteger rawState,
    NSInteger currentLimit
);
FOUNDATION_EXPORT NSInteger JSCResolveManualHoldLimit(
    NSInteger chargeLimit
);

FOUNDATION_EXPORT JSCOptimizedChargingState
JSCResolveOptimizedChargingState(NSUInteger rawState);

/// Pure interpretation of PowerUI's current raw UI state. This performs no
/// system I/O and exists separately so unknown macOS revisions can be covered
/// by fail-closed unit tests.
FOUNDATION_EXPORT JSCChargeHoldKind JSCResolveChargeHoldKind(
    NSUInteger rawState,
    BOOL chargingOverrideAllowed
);

/// Verifies that an object exposes the exact temporary-override selector ABI
/// required for the selected hold. This only inspects Objective-C metadata and
/// never invokes the action; the bridge uses the same check before publishing
/// an actionable hold.
FOUNDATION_EXPORT BOOL JSCChargeToFullActionIsAvailable(
    id client,
    JSCChargeHoldKind kind
);

/// Exercises the production hold reader against an injected client. Juice's
/// tests use this seam to cover inconsistent private-API responses without
/// constructing PowerUI or invoking a charging mutation.
FOUNDATION_EXPORT BOOL JSCCopyChargeHoldStatusForClient(
    id client,
    JSCChargeHoldKind * _Nullable kind,
    NSInteger * _Nullable chargeLimit,
    NSError * _Nullable * _Nullable error
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
/// choose the wrong operation. Successful calls return the authoritative hold
/// kind and limit that selected the action.
FOUNDATION_EXPORT BOOL JSCChargeToFull(
    JSCChargeHoldKind * _Nullable actedKind,
    NSInteger * _Nullable actedChargeLimit,
    NSError * _Nullable * _Nullable error
);

/// Reads macOS's manual charge-limit configuration. While Charge to Full is
/// active, `currentLimit` is the temporary target and `state` identifies that
/// it must not be presented as the saved persistent selection. A successful
/// call with `supported == NO` means this Mac does not offer Charge Limit;
/// changed, inconsistent, or missing private interfaces fail closed with `NO`.
FOUNDATION_EXPORT BOOL JSCCopyChargeLimitConfiguration(
    BOOL * _Nullable supported,
    NSInteger * _Nullable currentLimit,
    JSCChargeLimitOptions * _Nullable availableLimits,
    JSCChargeLimitState * _Nullable state,
    NSError * _Nullable * _Nullable error
);

/// Exercises the production Charge Limit reader against an injected client.
/// It performs reads only and exists so support/error behavior can be tested
/// without connecting to the machine's PowerUI service.
FOUNDATION_EXPORT BOOL JSCCopyChargeLimitConfigurationForClient(
    id client,
    BOOL * _Nullable supported,
    NSInteger * _Nullable currentLimit,
    JSCChargeLimitOptions * _Nullable availableLimits,
    JSCChargeLimitState * _Nullable state,
    NSError * _Nullable * _Nullable error
);

/// Sets the persistent manual charge limit to one of the choices macOS reports
/// as available. The available choices are re-read at action time so a stale
/// Settings window cannot send a value the current system no longer supports.
FOUNDATION_EXPORT BOOL JSCSetChargeLimit(
    NSInteger chargeLimit,
    NSError * _Nullable * _Nullable error
);

/// Reads the effective Optimized Battery Charging switch state used by System
/// Settings. A successful call with `supported == NO` means this Mac does not
/// offer the feature. Missing or changed private interfaces fail closed.
FOUNDATION_EXPORT BOOL JSCCopyOptimizedChargingConfiguration(
    BOOL * _Nullable supported,
    JSCOptimizedChargingState * _Nullable state,
    NSError * _Nullable * _Nullable error
);

/// Persistently enables or disables Optimized Battery Charging. The system
/// state and exact action selector are revalidated at action time.
FOUNDATION_EXPORT BOOL JSCSetOptimizedChargingEnabled(
    BOOL enabled,
    NSError * _Nullable * _Nullable error
);

/// Uses the same one-time disable action offered by System Settings. It does
/// not change the persistent Optimized Battery Charging preference.
FOUNDATION_EXPORT BOOL JSCTemporarilyDisableOptimizedCharging(
    NSError * _Nullable * _Nullable error
);

NS_ASSUME_NONNULL_END
