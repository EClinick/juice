using Juice.Core.Power;

namespace Juice.App.Monitoring;

/// <summary>
/// Folds the several independent signals Windows sends about visibility into the single
/// <see cref="ActivityState"/> the sampling policy takes.
/// </summary>
/// <remarks>
/// The signals overlap and arrive in any order: a laptop lid close produces a display
/// off notification and a session lock and then a suspend, and the resume path replays
/// them in a different order again. Tracking each flag separately and deriving the state
/// from a fixed precedence is what keeps a stale unlock notification from re-enabling
/// one second sampling on a sleeping machine.
/// </remarks>
public sealed class ActivityStateTracker
{
    private bool _isSuspended;
    private bool _isDisplayOff;
    private bool _isSessionLocked;
    private bool _isWindowVisible;

    /// <summary>Raised whenever the derived state changes.</summary>
    public event EventHandler<ActivityState>? StateChanged;

    /// <summary>The current derived state.</summary>
    public ActivityState State { get; private set; } = ActivityState.TrayOnly;

    /// <summary>Machine is entering or leaving modern standby.</summary>
    public bool IsSuspended
    {
        get => _isSuspended;
        set => Set(ref _isSuspended, value);
    }

    /// <summary>Display is off or dimmed.</summary>
    public bool IsDisplayOff
    {
        get => _isDisplayOff;
        set => Set(ref _isDisplayOff, value);
    }

    /// <summary>Session is locked.</summary>
    public bool IsSessionLocked
    {
        get => _isSessionLocked;
        set => Set(ref _isSessionLocked, value);
    }

    /// <summary>A Juice window is on screen.</summary>
    public bool IsWindowVisible
    {
        get => _isWindowVisible;
        set => Set(ref _isWindowVisible, value);
    }

    private void Set(ref bool field, bool value)
    {
        if (field == value) return;
        field = value;

        var next = Derive();
        if (next == State) return;

        State = next;
        StateChanged?.Invoke(this, next);
    }

    private ActivityState Derive()
    {
        if (_isSuspended) return ActivityState.Suspended;
        if (_isDisplayOff || _isSessionLocked) return ActivityState.DisplayOff;
        return _isWindowVisible ? ActivityState.Foreground : ActivityState.TrayOnly;
    }
}
