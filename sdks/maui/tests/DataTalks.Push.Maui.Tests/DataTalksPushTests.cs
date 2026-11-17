using Xunit;

// DataTalksPush is static: one test at a time.
[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace DataTalks.Push.Maui.Tests;

public sealed class DataTalksPushTests : IDisposable
{
    public DataTalksPushTests()
    {
        DataTalksPush.Reset();
    }

    public void Dispose()
    {
        DataTalksPush.Reset();
    }

    [Fact]
    public void Initialize_NeedsAKey_AndOpensLinksByDefault()
    {
        Assert.ThrowsAny<ArgumentException>(() => DataTalksPush.Initialize(string.Empty));

        DataTalksPush.Initialize("dtpk_stg_test_key");

        Assert.Equal("dtpk_stg_test_key", DataTalksPush.Initialized?.AppKey);
        Assert.Equal(new DataTalksPushOptions(BaseUrl: null, OpenLinks: true), DataTalksPush.Initialized?.Options);
    }

    [Fact]
    public void Initialize_PassesTheOptionsOn()
    {
        var options = new DataTalksPushOptions("http://10.0.2.2:5000/v1", OpenLinks: false);

        DataTalksPush.Initialize("dtpk_stg_test_key", options);

        Assert.Equal(options, DataTalksPush.Initialized?.Options);
    }

    [Theory]
    [InlineData("authorized", DataTalksPermission.Authorized)]
    [InlineData("denied", DataTalksPermission.Denied)]
    [InlineData("not_determined", DataTalksPermission.NotDetermined)]
    [InlineData("provisional", DataTalksPermission.Provisional)]
    [InlineData("ephemeral", DataTalksPermission.Ephemeral)]
    [InlineData("a name from a newer SDK", DataTalksPermission.NotDetermined)]
    [InlineData(null, DataTalksPermission.NotDetermined)]
    public async Task ThePermission_IsTheNativeSdksName(string? native, DataTalksPermission expected)
    {
        DataTalksPush.NativePermission = native;

        Assert.Equal(expected, await DataTalksPush.GetPermissionStatusAsync());
        Assert.Equal(expected, await DataTalksPush.RequestPermissionAsync());
    }

    [Fact]
    public async Task RequestPermission_PassesProvisionalOn()
    {
        DataTalksPush.NativePermission = "provisional";

        Assert.Equal(DataTalksPermission.Provisional, await DataTalksPush.RequestPermissionAsync(provisional: true));
        Assert.True(DataTalksPush.RequestedProvisional);
    }

    [Fact]
    public void ATapWithAHandler_ReachesItAtOnce_AndIsNotKept()
    {
        var first = Record();
        DataTalksPush.NativeOpened("myapp://tickets/1", """{"ticket_id":"T-1"}""");
        var second = Record();
        DataTalksPush.RunPosted();

        var opened = Assert.Single(first);
        Assert.Equal("myapp://tickets/1", opened.DeepLink);
        Assert.Equal("""{"ticket_id":"T-1"}""", opened.DataJson);
        Assert.Empty(second);
    }

    [Fact]
    public void ATapBeforeAnyHandler_ReachesTheFirstHandler_AfterItSubscribes()
    {
        DataTalksPush.NativeOpened("myapp://tickets/1", null);

        var first = Record();
        Assert.Empty(first); // Not from inside the subscribe: a page's constructor finishes first.

        DataTalksPush.RunPosted();
        Assert.Equal("myapp://tickets/1", Assert.Single(first).DeepLink);
    }

    [Fact]
    public void OnlyTheNewestTapIsKept_AndOnlyOnce()
    {
        DataTalksPush.NativeOpened("myapp://tickets/1", null);
        DataTalksPush.NativeOpened("myapp://tickets/2", null);

        var first = Record();
        DataTalksPush.RunPosted();
        var second = Record();
        DataTalksPush.RunPosted();

        Assert.Equal("myapp://tickets/2", Assert.Single(first).DeepLink);
        Assert.Empty(second);
    }

    [Fact]
    public void AfterTheLastHandlerGoes_ATapIsKeptAgain()
    {
        var gone = new List<DataTalksNotificationOpenedEventArgs>();
        EventHandler<DataTalksNotificationOpenedEventArgs> handler = (_, args) => gone.Add(args);
        DataTalksPush.NotificationOpened += handler;
        DataTalksPush.NotificationOpened -= handler;

        DataTalksPush.NativeOpened("myapp://tickets/3", null);
        var next = Record();
        DataTalksPush.RunPosted();

        Assert.Empty(gone);
        Assert.Equal("myapp://tickets/3", Assert.Single(next).DeepLink);
    }

    [Fact]
    public void AMessage_CarriesEveryField()
    {
        var received = new List<DataTalksMessageReceivedEventArgs>();
        DataTalksPush.MessageReceived += (_, args) => received.Add(args);

        DataTalksPush.NativeMessage("push-1", "Match day", "Gates open at 17:00.", "https://cdn.example.com/a.jpg", "https://example.com/t", """{"a":1}""");

        var message = Assert.Single(received);
        Assert.Equal("push-1", message.Uid);
        Assert.Equal("Match day", message.Title);
        Assert.Equal("Gates open at 17:00.", message.Body);
        Assert.Equal("https://cdn.example.com/a.jpg", message.ImageUrl);
        Assert.Equal("https://example.com/t", message.DeepLink);
        Assert.Equal("""{"a":1}""", message.DataJson);
    }

    [Fact]
    public void AnIdentityResult_CarriesTheAnswer()
    {
        var results = new List<DataTalksIdentityResultEventArgs>();
        DataTalksPush.IdentityResult += (_, args) => results.Add(args);

        DataTalksPush.NativeIdentityResult(true, null, null);
        DataTalksPush.NativeIdentityResult(false, "identity_token_invalid", "expired");

        Assert.Collection(
            results,
            accepted =>
            {
                Assert.True(accepted.Verified);
                Assert.Null(accepted.ErrorCode);
            },
            refused =>
            {
                Assert.False(refused.Verified);
                Assert.Equal("identity_token_invalid", refused.ErrorCode);
                Assert.Equal("expired", refused.ErrorDetail);
            });
    }

    private static List<DataTalksNotificationOpenedEventArgs> Record()
    {
        var opened = new List<DataTalksNotificationOpenedEventArgs>();
        DataTalksPush.NotificationOpened += (_, args) => opened.Add(args);
        return opened;
    }
}
