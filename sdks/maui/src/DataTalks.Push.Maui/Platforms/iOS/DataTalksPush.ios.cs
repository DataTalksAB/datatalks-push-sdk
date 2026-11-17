using CoreFoundation;
using DataTalks.Push.iOS;
using Foundation;
using UserNotifications;

namespace DataTalks.Push.Maui;

public static partial class DataTalksPush
{
    /// <summary>
    /// Forward <c>application:didRegisterForRemoteNotificationsWithDeviceToken:</c> here. <see cref="DataTalksPushApplicationDelegate"/> does it for you.
    /// </summary>
    public static void DidRegisterForRemoteNotifications(NSData deviceToken)
    {
        DTPBridge.DidRegisterForRemoteNotifications(deviceToken);
    }

    /// <summary>
    /// Forward <c>application:didFailToRegisterForRemoteNotificationsWithError:</c> here. <see cref="DataTalksPushApplicationDelegate"/> does it for you.
    /// </summary>
    public static void DidFailToRegisterForRemoteNotifications(NSError error)
    {
        DTPBridge.DidFailToRegisterForRemoteNotifications(error);
    }

    /// <summary>
    /// Makes the SDK the notification center's delegate. Notifications that aren't from Data Talks go on to the previous delegate.
    /// <see cref="MauiAppBuilderExtensions.UseDataTalksPush"/> calls it unless the app keeps its own delegate.
    /// </summary>
    public static void UseAsNotificationCenterDelegate()
    {
        DTPBridge.UseAsNotificationCenterDelegate();
    }

    /// <summary>
    /// For an app with its own <see cref="IUNUserNotificationCenterDelegate"/>: forward <c>DidReceiveNotificationResponse</c> here. Returns true
    /// for a Data Talks push, which the SDK has opened; false for any other, which the app handles.
    /// </summary>
    public static bool HandleNotificationResponse(UNNotificationResponse response)
    {
        return DTPBridge.HandleNotificationResponse(response);
    }

    /// <summary>
    /// For an app with its own <see cref="IUNUserNotificationCenterDelegate"/>: forward <c>WillPresentNotification</c> here. Returns the options to
    /// show a Data Talks push with while the app is open, or null for any other, which the app handles.
    /// </summary>
    public static UNNotificationPresentationOptions? HandleWillPresent(UNNotification notification)
    {
        return DTPBridge.PresentationOptions(notification) is { } options ? (UNNotificationPresentationOptions)options.UInt64Value : null;
    }

    private static partial void PlatformInitialize(string appKey, DataTalksPushOptions options)
    {
        DTPBridge.SetListener(new NativeListener());
        DTPBridge.Initialize(appKey, options.BaseUrl, options.OpenLinks);
    }

    // The bridge answers on the main thread, with the permission's name.
    private static partial Task<DataTalksPermission> PlatformRequestPermissionAsync(bool provisional)
    {
        var answer = new TaskCompletionSource<DataTalksPermission>(TaskCreationOptions.RunContinuationsAsynchronously);
        DTPBridge.RequestPermission(provisional, permission => answer.TrySetResult(ParsePermission(permission)));
        return answer.Task;
    }

    private static partial Task<DataTalksPermission> PlatformGetPermissionStatusAsync()
    {
        var answer = new TaskCompletionSource<DataTalksPermission>(TaskCreationOptions.RunContinuationsAsynchronously);
        DTPBridge.PermissionStatus(permission => answer.TrySetResult(ParsePermission(permission)));
        return answer.Task;
    }

    private static partial void PlatformIdentify(string? externalId, string? email, string? identityToken)
    {
        DTPBridge.Identify(externalId, email, identityToken);
    }

    private static partial void PlatformLogout()
    {
        DTPBridge.Logout();
    }

    private static partial void PlatformSetMarketingOptIn(bool optIn)
    {
        DTPBridge.SetMarketingOptIn(optIn);
    }

    private static partial void PlatformDeleteLocalData()
    {
        DTPBridge.DeleteLocalData();
    }

    private static partial void PlatformPost(Action action)
    {
        DispatchQueue.MainQueue.DispatchAsync(action);
    }

    private sealed class NativeListener : DTPBridgeListener
    {
        public override void NotificationOpened(string? deepLink, string? dataJson)
        {
            RaiseNotificationOpened(deepLink, dataJson);
        }

        public override void MessageReceived(string? uid, string? title, string? body, string? imageUrl, string? deepLink, string? dataJson)
        {
            RaiseMessageReceived(uid, title, body, imageUrl, deepLink, dataJson);
        }

        public override void IdentityResult(bool verified, string? errorCode, string? errorDetail)
        {
            RaiseIdentityResult(verified, errorCode, errorDetail);
        }
    }
}
