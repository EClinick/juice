using Windows.ApplicationModel;

namespace Juice.App.Services;

/// <summary>
/// Wraps the packaged startup task declared in <c>Package.appxmanifest</c>.
/// </summary>
/// <remarks>
/// A packaged app must not write its own Run key: Windows owns the decision, surfaces it
/// in Task Manager's Startup tab, and can veto it. Once the user has disabled Juice
/// there, <see cref="StartupTask.RequestEnableAsync"/> silently returns the disabled
/// state, which is why <see cref="SetEnabledAsync"/> reports what it actually achieved
/// rather than what was asked for.
/// </remarks>
public static class StartupTaskService
{
    /// <summary>Must match the TaskId in the package manifest.</summary>
    private const string TaskId = "JuiceStartup";

    /// <summary>True when Juice currently starts with Windows.</summary>
    public static async Task<bool> IsEnabledAsync()
    {
        var task = await TryGetAsync();
        return task?.State is StartupTaskState.Enabled or StartupTaskState.EnabledByPolicy;
    }

    /// <summary>True when the user has switched Juice off in Task Manager.</summary>
    public static async Task<bool> IsBlockedByUserAsync()
    {
        var task = await TryGetAsync();
        return task?.State is StartupTaskState.DisabledByUser or StartupTaskState.DisabledByPolicy;
    }

    /// <summary>
    /// Requests the new state and returns the state Windows actually settled on.
    /// </summary>
    public static async Task<bool> SetEnabledAsync(bool enabled)
    {
        var task = await TryGetAsync();
        if (task is null) return false;

        if (!enabled)
        {
            task.Disable();
            return false;
        }

        var state = await task.RequestEnableAsync();
        return state is StartupTaskState.Enabled or StartupTaskState.EnabledByPolicy;
    }

    private static async Task<StartupTask?> TryGetAsync()
    {
        try
        {
            return await StartupTask.GetAsync(TaskId);
        }
        catch (Exception ex) when (ex is InvalidOperationException or ArgumentException)
        {
            // No package identity, so there is no startup task to talk to.
            return null;
        }
    }
}
