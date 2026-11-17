using Foundation;

namespace DataTalksPushMauiSample;

// Info.plist's UIApplicationSceneManifest names this class. An app built with the iOS 27 SDK must use scenes, or it stops at launch.
// MAUI's base class creates the window; the APNs callbacks and the notification delegate stay on the app, so the SDK needs nothing here.
[Register("SceneDelegate")]
public class SceneDelegate : MauiUISceneDelegate
{
}
