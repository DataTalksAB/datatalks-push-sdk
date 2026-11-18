namespace DataTalks.Push.Maui;

/// <summary>
/// Data Talks push notifications on Android and iOS. The native SDK does the work: these calls return at once, and results arrive through
/// the events, on the main thread. <see cref="MauiAppBuilderExtensions.UseDataTalksPush"/> calls <see cref="Initialize"/> at app start.
/// </summary>
public static partial class DataTalksPush
{
    private static readonly object OpenedLock = new();
    private static EventHandler<DataTalksNotificationOpenedEventArgs>? _notificationOpened;
    private static DataTalksNotificationOpenedEventArgs? _heldOpen;

    /// <summary>
    /// The user tapped a notification. With <see cref="DataTalksPushOptions.OpenLinks"/> on, the SDK opens its link; with it off, the app routes it.
    /// The newest tap that arrived while nothing was subscribed, such as the one that launched the app, goes once to the first handler, after it
    /// subscribes.
    /// </summary>
    public static event EventHandler<DataTalksNotificationOpenedEventArgs>? NotificationOpened
    {
        add
        {
            if (value is null)
            {
                return;
            }

            DataTalksNotificationOpenedEventArgs? held;
            lock (OpenedLock)
            {
                _notificationOpened += value;
                held = _heldOpen;
                _heldOpen = null;
            }

            if (held is not null)
            {
                // Posted even on the main thread, as the native SDKs do: the handler gets it after subscribing, not inside a
                // page's constructor.
                PlatformPost(() => value(null, held));
            }
        }

        remove
        {
            lock (OpenedLock)
            {
                _notificationOpened -= value;
            }
        }
    }

    /// <summary>A Data Talks push arrived. On iOS, only while the app is open.</summary>
    public static event EventHandler<DataTalksMessageReceivedEventArgs>? MessageReceived;

    /// <summary>The service answered an <see cref="Identify"/>.</summary>
    public static event EventHandler<DataTalksIdentityResultEventArgs>? IdentityResult;

    /// <summary>Starts the SDK with the app's publishable key. The host comes from the key.</summary>
    public static void Initialize(string appKey, DataTalksPushOptions? options = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(appKey);
        PlatformInitialize(appKey, options ?? new DataTalksPushOptions());
    }

    /// <summary>
    /// Asks for the notification permission: the Android 13 prompt, or alert, sound and badge on iOS. On iOS, <paramref name="provisional"/> shows
    /// no prompt and pushes arrive quietly. The task returns the answer, or the current status when no prompt can show (Android before 13, the
    /// permission already granted, no activity on screen). The SDK reports changes to the service itself.
    /// </summary>
    public static Task<DataTalksPermission> RequestPermissionAsync(bool provisional = false)
    {
        return PlatformRequestPermissionAsync(provisional);
    }

    /// <summary>
    /// Whether this app may show notifications. <see cref="DataTalksPermission.NotDetermined"/> until the app asks: on iOS, and on Android 13 and later.
    /// </summary>
    public static Task<DataTalksPermission> GetPermissionStatusAsync()
    {
        return PlatformGetPermissionStatusAsync();
    }

    /// <summary>
    /// Links this install to the signed-in user. Pass the <paramref name="identityToken"/> your backend signed for this user; an app that requires
    /// verified identity refuses a call without one. The answer reaches <see cref="IdentityResult"/>. A refused identify isn't retried: call it again
    /// at the next sign-in. Repeating the same external id and email (with or without a token, as before) on the same UTC day doesn't call the service:
    /// <see cref="IdentityResult"/> gets the earlier answer, which says nothing about this call's token. A token-only identify is always sent.
    /// </summary>
    public static void Identify(string? externalId = null, string? email = null, string? identityToken = null)
    {
        PlatformIdentify(externalId, email, identityToken);
    }

    /// <summary>
    /// For apps whose iOS pushes go through their own Firebase project (transport FCM in the portal): pass the FCM registration token each time
    /// Firebase Messaging reports it. A null or empty token is ignored. On Android the SDK reads the token itself, so the call does nothing there.
    /// </summary>
    public static void SetFcmToken(string? token)
    {
        if (string.IsNullOrEmpty(token))
        {
            return;
        }

        PlatformSetFcmToken(token);
    }

    /// <summary>Unlinks this install from its user. The install stays registered.</summary>
    public static void Logout()
    {
        PlatformLogout();
    }

    /// <summary>Records the user's in-app marketing choice on this device. Transactional pushes aren't affected.</summary>
    public static void SetMarketingOptIn(bool optIn)
    {
        PlatformSetMarketingOptIn(optIn);
    }

    /// <summary>Deletes this install on the service and everything the SDK keeps on the device. The SDK stays off until the next <see cref="Initialize"/>.</summary>
    public static void DeleteLocalData()
    {
        PlatformDeleteLocalData();
    }

    private static partial void PlatformInitialize(string appKey, DataTalksPushOptions options);

    private static partial Task<DataTalksPermission> PlatformRequestPermissionAsync(bool provisional);

    private static partial Task<DataTalksPermission> PlatformGetPermissionStatusAsync();

    private static partial void PlatformIdentify(string? externalId, string? email, string? identityToken);

    private static partial void PlatformSetFcmToken(string token);

    private static partial void PlatformLogout();

    private static partial void PlatformSetMarketingOptIn(bool optIn);

    private static partial void PlatformDeleteLocalData();

    /// <summary>Runs <paramref name="action"/> on the main thread, always later, never inline.</summary>
    private static partial void PlatformPost(Action action);

    /// <summary>Both native SDKs use the service's permission names.</summary>
    private static DataTalksPermission ParsePermission(string? value)
    {
        return value switch
        {
            "authorized" => DataTalksPermission.Authorized,
            "denied" => DataTalksPermission.Denied,
            "provisional" => DataTalksPermission.Provisional,
            "ephemeral" => DataTalksPermission.Ephemeral,
            _ => DataTalksPermission.NotDetermined,
        };
    }

    // The native SDK hands a held tap to the first native listener, which this wrapper sets at start, before the app subscribes. So the tap
    // is held again here until the app's first handler.
    private static void RaiseNotificationOpened(string? deepLink, string? dataJson)
    {
        var args = new DataTalksNotificationOpenedEventArgs(deepLink, dataJson);
        EventHandler<DataTalksNotificationOpenedEventArgs>? handlers;
        lock (OpenedLock)
        {
            handlers = _notificationOpened;
            if (handlers is null)
            {
                _heldOpen = args;
                return;
            }
        }

        handlers(null, args);
    }

    private static void RaiseMessageReceived(string? uid, string? title, string? body, string? imageUrl, string? deepLink, string? dataJson)
    {
        MessageReceived?.Invoke(null, new DataTalksMessageReceivedEventArgs(uid, title, body, imageUrl, deepLink, dataJson));
    }

    private static void RaiseIdentityResult(bool verified, string? errorCode, string? errorDetail)
    {
        IdentityResult?.Invoke(null, new DataTalksIdentityResultEventArgs(verified, errorCode, errorDetail));
    }
}

/// <param name="BaseUrl">Replaces the host the key selects. Only for testing against a local ingress.</param>
/// <param name="OpenLinks">
/// True, the default, opens a push's link as a native app does: an https link through the system, any other scheme inside the app. False leaves
/// the link to the app: a tap opens the app and reports the link to <see cref="DataTalksPush.NotificationOpened"/>.
/// </param>
public sealed record DataTalksPushOptions(string? BaseUrl = null, bool OpenLinks = true);

/// <summary>Whether this app may show notifications.</summary>
public enum DataTalksPermission
{
    Authorized,
    Denied,

    /// <summary>The app hasn't asked yet: on iOS, and on Android 13 and later.</summary>
    NotDetermined,

    /// <summary>iOS: pushes arrive quietly, in the notification center only.</summary>
    Provisional,

    /// <summary>iOS: an App Clip's temporary permission.</summary>
    Ephemeral,
}

public sealed class DataTalksNotificationOpenedEventArgs(string? deepLink, string? dataJson) : EventArgs
{
    /// <summary>The push's link, if it has one.</summary>
    public string? DeepLink { get; } = deepLink;

    /// <summary>The push's data as a JSON object, if it has any.</summary>
    public string? DataJson { get; } = dataJson;
}

/// <summary>A Data Talks push. On iOS, raised only while the app is open; otherwise the system shows it.</summary>
public sealed class DataTalksMessageReceivedEventArgs(string? uid, string? title, string? body, string? imageUrl, string? deepLink, string? dataJson) : EventArgs
{
    public string? Uid { get; } = uid;

    public string? Title { get; } = title;

    public string? Body { get; } = body;

    /// <summary>The picture's https URL. On iOS, showing it needs a Notification Service Extension.</summary>
    public string? ImageUrl { get; } = imageUrl;

    public string? DeepLink { get; } = deepLink;

    public string? DataJson { get; } = dataJson;
}

/// <summary>
/// The answer to an identify. When <see cref="ErrorCode"/> is set, the identify was refused and isn't retried; <see cref="ErrorDetail"/> says why
/// an identity token failed. It never says whether a profile was found.
/// </summary>
public sealed class DataTalksIdentityResultEventArgs(bool verified, string? errorCode, string? errorDetail) : EventArgs
{
    public bool Verified { get; } = verified;

    public string? ErrorCode { get; } = errorCode;

    public string? ErrorDetail { get; } = errorDetail;
}
