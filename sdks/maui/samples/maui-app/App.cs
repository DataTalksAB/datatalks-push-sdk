namespace DataTalksPushMauiSample;

public sealed class App : Application
{
    protected override Window CreateWindow(IActivationState? activationState)
    {
        var page = new MainPage();
        var window = new Window(page);
        window.Resumed += (_, _) => page.RefreshPermission();
        return window;
    }
}
