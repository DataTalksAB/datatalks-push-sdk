using Android.Content;
using Android.OS;
using Android.Util;
using Firebase.Messaging;
using Microsoft.Maui.ApplicationModel;
using Org.Json;
using IDataTalksPermissionCallback = DataTalks.Push.Android.IDataTalksPermissionCallback;
using NativeMessage = DataTalks.Push.Android.DataTalksMessage;
using NativeOptions = DataTalks.Push.Android.DataTalksPushOptions;
using NativePermission = DataTalks.Push.Android.DataTalksPermission;
using NativePush = DataTalks.Push.Android.DataTalksPush;
using NativeResult = DataTalks.Push.Android.DataTalksIdentityResult;

namespace DataTalks.Push.Maui;

public static partial class DataTalksPush
{
    private const string LogTag = "DataTalksPush";

    /// <summary>
    /// For an app with its own <c>FirebaseMessagingService</c>: forward <c>OnMessageReceived</c> here. Returns true for a Data Talks push, which the
    /// SDK has shown; false for any other, which the app handles.
    /// </summary>
    public static bool HandleRemoteMessage(Context context, RemoteMessage message)
    {
        return NativePush.HandleRemoteMessage(context, message);
    }

    /// <summary>For an app with its own <c>FirebaseMessagingService</c>: forward <c>OnNewToken</c> and <c>OnRegistered</c> here.</summary>
    public static void OnNewRegistration(Context context, string value)
    {
        NativePush.OnNewRegistration(context, value);
    }

    private static partial void PlatformInitialize(string appKey, DataTalksPushOptions options)
    {
        NativePush.SetListener(new NativeListener());
        NativePush.Initialize(global::Android.App.Application.Context, appKey, new NativeOptions(options.BaseUrl, options.OpenLinks));
    }

    // Android has no provisional permission: the SDK asks from a transparent activity of its own, and answers on the main thread.
    private static partial Task<DataTalksPermission> PlatformRequestPermissionAsync(bool provisional)
    {
        if (Platform.CurrentActivity is not { } activity)
        {
            Log.Warn(LogTag, "RequestPermissionAsync needs an activity on screen: it answers with the status instead.");
            return PlatformGetPermissionStatusAsync();
        }

        var answer = new TaskCompletionSource<DataTalksPermission>(TaskCreationOptions.RunContinuationsAsynchronously);
        NativePush.RequestPermission(activity, new PermissionCallback(answer));
        return answer.Task;
    }

    private static partial Task<DataTalksPermission> PlatformGetPermissionStatusAsync()
    {
        return Task.FromResult(ParsePermission(NativePush.PermissionStatus(global::Android.App.Application.Context).Value));
    }

    private static partial void PlatformIdentify(string? externalId, string? email, string? identityToken)
    {
        NativePush.Identify(externalId, email, identityToken);
    }

    private static partial void PlatformLogout()
    {
        NativePush.Logout();
    }

    private static partial void PlatformSetMarketingOptIn(bool optIn)
    {
        NativePush.SetMarketingOptIn(optIn);
    }

    private static partial void PlatformDeleteLocalData()
    {
        NativePush.DeleteLocalData();
    }

    private static partial void PlatformPost(Action action)
    {
        new Handler(Looper.MainLooper!).Post(action);
    }

    private sealed class PermissionCallback(TaskCompletionSource<DataTalksPermission> answer) : Java.Lang.Object, IDataTalksPermissionCallback
    {
        public void OnResult(NativePermission permission)
        {
            answer.TrySetResult(ParsePermission(permission.Value));
        }
    }

    private sealed class NativeListener : Java.Lang.Object, DataTalks.Push.Android.IDataTalksPushListener
    {
        public void OnNotificationOpened(string? deepLink, JSONObject? data)
        {
            RaiseNotificationOpened(deepLink, data?.ToString());
        }

        public void OnMessageReceived(NativeMessage message)
        {
            RaiseMessageReceived(message.Uid, message.Title, message.Body, message.ImageUrl, message.DeepLink, message.Data?.ToString());
        }

        public void OnIdentityResult(NativeResult result)
        {
            RaiseIdentityResult(result.Verified, result.ErrorCode, result.ErrorDetail);
        }
    }
}
