using DataTalks.Push.Maui;
using Microsoft.Maui.Controls.Shapes;

namespace DataTalksPushMauiSample;

/// <summary>
/// The sandbox demo: start the SDK with a key, ask for the permission, identify with a token pasted from the portal's
/// "Test a token", log out, consent, delete, and a log of what the SDK reports.
/// </summary>
public sealed class MainPage : ContentPage
{
    public const string AppKeySetting = "app_key";
    public const string BaseUrlSetting = "base_url";

    private static readonly Color Orange = Color.FromArgb("#F35625");
    private static readonly Color Indigo = Color.FromArgb("#1F1451");
    private static readonly Color PageColor = Color.FromArgb("#EEF1F8");
    private static readonly Color Muted = Color.FromArgb("#5E6278");

    private readonly Entry _appKey = Field("App key");
    private readonly Label _keyDescription = Hint(string.Empty);
    private readonly Entry _baseUrl = Field("Host, only for a local ingress");
    private readonly Entry _externalId = Field("External id");
    private readonly Entry _email = Field("Email", Keyboard.Email);
    private readonly Entry _identityToken = Field("Identity token");
    private readonly VerticalStackLayout _events = new() { Spacing = 6 };
    private readonly Label _noEvents = Hint("Nothing yet. Taps, pushes and identify answers show here.");
    private readonly Label _permission = Hint("Permission: unknown");

    public MainPage()
    {
        // The header's indigo extends under the status bar; the cards sit on the light page colour.
        BackgroundColor = Indigo;
        _appKey.Text = Preferences.Default.Get<string?>(AppKeySetting, null);
        _baseUrl.Text = Preferences.Default.Get<string?>(BaseUrlSetting, null);
        _keyDescription.Text = DescribeKey(_appKey.Text);
        _appKey.TextChanged += (_, args) => _keyDescription.Text = DescribeKey(args.NewTextValue);
        _events.Add(_noEvents);

        var optIn = new Switch { IsToggled = true, OnColor = Orange };
        optIn.Toggled += (_, args) => DataTalksPush.SetMarketingOptIn(args.Value);

        var cards = new VerticalStackLayout
        {
            Padding = 16,
            Spacing = 12,
            Children =
            {
                Card(
                    "App",
                    _appKey,
                    _keyDescription,
                    _baseUrl,
                    Buttons(Primary("Register", Register), Secondary("Ask for permission", RequestPermission)),
                    _permission),
                Card(
                    "User",
                    _externalId,
                    _email,
                    _identityToken,
                    Hint("Paste a token from the portal's Test a token, or leave it empty for an unverified identify."),
                    Buttons(Primary("Identify", () => DataTalksPush.Identify(Text(_externalId), Text(_email), Text(_identityToken))), Secondary("Log out", DataTalksPush.Logout))),
                Card(
                    "Device",
                    new HorizontalStackLayout { Spacing = 8, Children = { optIn, new Label { Text = "Marketing pushes", VerticalOptions = LayoutOptions.Center } } },
                    Buttons(Secondary("Delete local data", DataTalksPush.DeleteLocalData)),
                    Hint("Deletes this install on the service too. Register starts a new one.")),
                Card("Events", _events),
            },
        };

        var page = new Grid { RowDefinitions = { new RowDefinition(GridLength.Auto), new RowDefinition(GridLength.Star) } };
        page.Add(Header(), 0, 0);
        page.Add(new ScrollView { BackgroundColor = PageColor, Content = cards }, 0, 1);
        Content = page;

        DataTalksPush.NotificationOpened += (_, args) => Report($"Opened: {args.DeepLink ?? "the app"}, data: {args.DataJson ?? "none"}");
        DataTalksPush.MessageReceived += (_, args) =>
        {
            var text = string.Join(' ', new[] { args.Title, args.Body }.Where(part => !string.IsNullOrEmpty(part)));
            Report($"Message {args.Uid ?? "without an id"}{(text.Length > 0 ? $": {text}" : string.Empty)}");
        };
        DataTalksPush.IdentityResult += (_, args) => Report(args.ErrorCode is { } code
            ? $"Identify refused: {code} {args.ErrorDetail}".Trim()
            : $"Identify accepted, verified: {(args.Verified ? "true" : "false")}");
    }

    private static Grid Header()
    {
        var header = new Grid
        {
            BackgroundColor = Indigo,
            Padding = new Thickness(16, 14),
            ColumnSpacing = 12,
            ColumnDefinitions = { new ColumnDefinition(GridLength.Auto), new ColumnDefinition(GridLength.Star), new ColumnDefinition(GridLength.Auto) },
        };

        var platform = DeviceInfo.Platform == DevicePlatform.iOS ? "iOS" : "Android";
        header.Add(new Image { Source = "datatalks_mark.png", WidthRequest = 40, HeightRequest = 40 }, 0, 0);
        header.Add(
            new VerticalStackLayout
            {
                Spacing = 2,
                VerticalOptions = LayoutOptions.Center,
                Children =
                {
                    new Label { Text = "Data Talks", TextColor = Colors.White, FontSize = 20, FontAttributes = FontAttributes.Bold },
                    new Label { Text = $"Push SDK demo · MAUI {platform}", TextColor = Colors.White.WithAlpha(0.7f), FontSize = 13 },
                },
            },
            1,
            0);
        header.Add(
            new Border
            {
                BackgroundColor = Colors.White,
                StrokeThickness = 0,
                StrokeShape = new RoundRectangle { CornerRadius = 12 },
                Padding = new Thickness(10, 4),
                VerticalOptions = LayoutOptions.Center,
                Content = new Label { Text = "SANDBOX", TextColor = Indigo, FontSize = 11, FontAttributes = FontAttributes.Bold, CharacterSpacing = 1.5 },
            },
            2,
            0);
        return header;
    }

    private static Border Card(string title, params View[] children)
    {
        var stack = new VerticalStackLayout { Spacing = 8 };
        stack.Add(new Label { Text = title.ToUpperInvariant(), TextColor = Indigo, FontSize = 12, FontAttributes = FontAttributes.Bold, CharacterSpacing = 1 });
        foreach (var child in children)
        {
            stack.Add(child);
        }

        return new Border
        {
            BackgroundColor = Colors.White,
            StrokeThickness = 0,
            StrokeShape = new RoundRectangle { CornerRadius = 12 },
            Padding = 16,
            Content = stack,
        };
    }

    private static HorizontalStackLayout Buttons(params Button[] buttons)
    {
        var row = new HorizontalStackLayout { Spacing = 8 };
        foreach (var button in buttons)
        {
            row.Add(button);
        }

        return row;
    }

    private static Button Primary(string text, Action action)
    {
        var button = new Button { Text = text, BackgroundColor = Orange, TextColor = Colors.White, CornerRadius = 20, FontAttributes = FontAttributes.Bold };
        button.Clicked += (_, _) => action();
        return button;
    }

    private static Button Secondary(string text, Action action)
    {
        var button = new Button { Text = text, BackgroundColor = Colors.White, TextColor = Orange, BorderColor = Orange, BorderWidth = 1.5, CornerRadius = 20, FontAttributes = FontAttributes.Bold };
        button.Clicked += (_, _) => action();
        return button;
    }

    private static Entry Field(string placeholder, Keyboard? keyboard = null)
    {
        return new Entry { Placeholder = placeholder, IsSpellCheckEnabled = false, IsTextPredictionEnabled = false, Keyboard = keyboard ?? Keyboard.Plain };
    }

    private static Label Hint(string text)
    {
        return new Label { Text = text, TextColor = Muted, FontSize = 13 };
    }

    private static string? Text(Entry entry)
    {
        return string.IsNullOrWhiteSpace(entry.Text) ? null : entry.Text.Trim();
    }

    private static string DescribeKey(string? key)
    {
        var parts = (key ?? string.Empty).Trim().Split('_');
        if (parts.Length < 3 || parts[0] != "dtpk" || parts[1] is not ("stg" or "prd"))
        {
            return "The app key from the portal's push app, dtpk_prd_…";
        }

        return parts[1] == "stg" ? "Staging app key" : "Production app key";
    }

    /// <summary>The permission can change in the system's settings while the app is away, so the window calls this when it comes back.</summary>
    public async void RefreshPermission()
    {
        _permission.Text = $"Permission: {Name(await DataTalksPush.GetPermissionStatusAsync())}";
    }

    protected override void OnAppearing()
    {
        base.OnAppearing();
        RefreshPermission();
    }

    // The permission names the other demos and the service use.
    private static string Name(DataTalksPermission permission)
    {
        return permission == DataTalksPermission.NotDetermined ? "not_determined" : permission.ToString().ToLowerInvariant();
    }

    private async void RequestPermission()
    {
        var permission = await DataTalksPush.RequestPermissionAsync();
        _permission.Text = $"Permission: {Name(permission)}";
        Report($"Permission: {Name(permission)}");
    }

    private void Register()
    {
        if (Text(_appKey) is not { } appKey)
        {
            Report("Enter an app key first.");
            return;
        }

        var baseUrl = Text(_baseUrl);
        Preferences.Default.Set(AppKeySetting, appKey);
        Preferences.Default.Set(BaseUrlSetting, baseUrl);

#if IOS
        DataTalksPush.UseAsNotificationCenterDelegate();
#endif
        DataTalksPush.Initialize(appKey, new DataTalksPushOptions(baseUrl));
    }

    private void Report(string line)
    {
        MainThread.BeginInvokeOnMainThread(() =>
        {
            _events.Remove(_noEvents);
            _events.Insert(0, new Label { Text = line, FontSize = 13 });
        });
    }
}
