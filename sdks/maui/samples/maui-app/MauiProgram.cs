using DataTalks.Push.Maui;

namespace DataTalksPushMauiSample;

public static class MauiProgram
{
    public static MauiApp CreateMauiApp()
    {
        var builder = MauiApp.CreateBuilder();
        builder.UseMauiApp<App>();

        // A real app passes its key here. The sample reads it from the screen, so on first launch the SDK starts when you press Register.
        if (Preferences.Default.Get<string?>(MainPage.AppKeySetting, null) is { } appKey)
        {
            builder.UseDataTalksPush(appKey, new DataTalksPushOptions(Preferences.Default.Get<string?>(MainPage.BaseUrlSetting, null)));
        }

        return builder.Build();
    }
}
