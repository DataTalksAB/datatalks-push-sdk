namespace DataTalks.Push.Maui;

/// <summary>
/// The platform code of <see cref="DataTalksPush"/> for the tests: it records what the shared code asks of the native SDK, answers
/// as the native SDK would, and holds what the shared code posts to the main thread until a test runs it.
/// </summary>
public static partial class DataTalksPush
{
    internal static readonly List<Action> Posted = [];

    internal static (string AppKey, DataTalksPushOptions Options)? Initialized { get; private set; }

    internal static bool? RequestedProvisional { get; private set; }

    internal static List<string> FcmTokens { get; } = [];

    /// <summary>The permission name the fake native SDK returns for a request and for a status check.</summary>
    internal static string? NativePermission { get; set; }

    internal static void Reset()
    {
        lock (OpenedLock)
        {
            _notificationOpened = null;
            _heldOpen = null;
        }

        MessageReceived = null;
        IdentityResult = null;
        Posted.Clear();
        Initialized = null;
        RequestedProvisional = null;
        NativePermission = null;
        FcmTokens.Clear();
    }

    /// <summary>Runs what was posted to the main thread, as the next run loop turn would.</summary>
    internal static void RunPosted()
    {
        var actions = Posted.ToArray();
        Posted.Clear();
        foreach (var action in actions)
        {
            action();
        }
    }

    // What the native listeners call.
    internal static void NativeOpened(string? deepLink, string? dataJson) => RaiseNotificationOpened(deepLink, dataJson);

    internal static void NativeMessage(string? uid, string? title, string? body, string? imageUrl, string? deepLink, string? dataJson) =>
        RaiseMessageReceived(uid, title, body, imageUrl, deepLink, dataJson);

    internal static void NativeIdentityResult(bool verified, string? errorCode, string? errorDetail) =>
        RaiseIdentityResult(verified, errorCode, errorDetail);

    private static partial void PlatformInitialize(string appKey, DataTalksPushOptions options) => Initialized = (appKey, options);

    private static partial Task<DataTalksPermission> PlatformRequestPermissionAsync(bool provisional)
    {
        RequestedProvisional = provisional;
        return Task.FromResult(ParsePermission(NativePermission));
    }

    private static partial Task<DataTalksPermission> PlatformGetPermissionStatusAsync() => Task.FromResult(ParsePermission(NativePermission));

    private static partial void PlatformIdentify(string? externalId, string? email, string? identityToken)
    {
    }

    private static partial void PlatformLogout()
    {
    }

    private static partial void PlatformSetFcmToken(string token) => FcmTokens.Add(token);

    private static partial void PlatformSetMarketingOptIn(bool optIn)
    {
    }

    private static partial void PlatformDeleteLocalData()
    {
    }

    private static partial void PlatformPost(Action action) => Posted.Add(action);
}
