using Foundation;
using Microsoft.Maui;
using UIKit;

namespace DataTalks.Push.Maui;

/// <summary>
/// An <c>AppDelegate</c> that forwards the APNs callbacks, which MAUI has no lifecycle events for. Derive the app's from this class, or forward
/// them yourself with <see cref="DataTalksPush.DidRegisterForRemoteNotifications"/> and <see cref="DataTalksPush.DidFailToRegisterForRemoteNotifications"/>.
/// </summary>
public abstract class DataTalksPushApplicationDelegate : MauiUIApplicationDelegate
{
    [Export("application:didRegisterForRemoteNotificationsWithDeviceToken:")]
    public void DidRegisterForRemoteNotifications(UIApplication application, NSData deviceToken)
    {
        DataTalksPush.DidRegisterForRemoteNotifications(deviceToken);
    }

    [Export("application:didFailToRegisterForRemoteNotificationsWithError:")]
    public void DidFailToRegisterForRemoteNotifications(UIApplication application, NSError error)
    {
        DataTalksPush.DidFailToRegisterForRemoteNotifications(error);
    }
}
