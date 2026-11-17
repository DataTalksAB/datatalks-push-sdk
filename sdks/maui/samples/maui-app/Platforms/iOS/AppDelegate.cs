using DataTalks.Push.Maui;
using Foundation;

namespace DataTalksPushMauiSample;

[Register("AppDelegate")]
public class AppDelegate : DataTalksPushApplicationDelegate
{
    protected override MauiApp CreateMauiApp()
    {
        return MauiProgram.CreateMauiApp();
    }
}
