using Microsoft.Maui.Hosting;
using Microsoft.Maui.LifecycleEvents;

namespace DataTalks.Push.Maui;

public static class MauiAppBuilderExtensions
{
    /// <summary>
    /// Starts the SDK at app start, early enough to receive the tap that launched the app. Set <paramref name="ownNotificationDelegate"/> on an
    /// iOS app that keeps its own notification delegate and forwards to <c>HandleWillPresent</c> and <c>HandleNotificationResponse</c>.
    /// </summary>
    public static MauiAppBuilder UseDataTalksPush(this MauiAppBuilder builder, string appKey, DataTalksPushOptions? options = null, bool ownNotificationDelegate = false)
    {
        builder.ConfigureLifecycleEvents(events =>
        {
#if ANDROID
            events.AddAndroid(android => android.OnApplicationCreate(_ => DataTalksPush.Initialize(appKey, options)));
#elif IOS
            events.AddiOS(ios => ios.FinishedLaunching((_, _) =>
            {
                if (!ownNotificationDelegate)
                {
                    DataTalksPush.UseAsNotificationCenterDelegate();
                }

                DataTalksPush.Initialize(appKey, options);
                return true;
            }));
#endif
        });

        return builder;
    }
}
