using Foundation;
using UserNotifications;

namespace DataTalks.Push.iOS;

/// <summary>sdks/maui/native/ios/Bridge/DTPBridge.swift, as .NET sees it.</summary>
[Protocol]
[Model]
[BaseType(typeof(NSObject))]
interface DTPBridgeListener
{
    [Abstract]
    [Export("notificationOpenedWithDeepLink:dataJson:")]
    void NotificationOpened([NullAllowed] string deepLink, [NullAllowed] string dataJson);

    [Abstract]
    [Export("messageReceivedWithUid:title:body:imageUrl:deepLink:dataJson:")]
    void MessageReceived(
        [NullAllowed] string uid,
        [NullAllowed] string title,
        [NullAllowed] string body,
        [NullAllowed] string imageUrl,
        [NullAllowed] string deepLink,
        [NullAllowed] string dataJson);

    [Abstract]
    [Export("identityResultWithVerified:errorCode:errorDetail:")]
    void IdentityResult(bool verified, [NullAllowed] string errorCode, [NullAllowed] string errorDetail);
}

interface IDTPBridgeListener
{
}

/// <summary>The permission's name: authorized, denied, not_determined, provisional or ephemeral.</summary>
delegate void DTPPermissionCompletion(string permission);

[BaseType(typeof(NSObject))]
interface DTPBridge
{
    [Static]
    [Export("setListener:")]
    void SetListener([NullAllowed] IDTPBridgeListener listener);

    [Static]
    [Export("initializeWithAppKey:baseUrl:openLinks:")]
    void Initialize(string appKey, [NullAllowed] string baseUrl, bool openLinks);

    [Static]
    [Export("didRegisterForRemoteNotificationsWithDeviceToken:")]
    void DidRegisterForRemoteNotifications(NSData deviceToken);

    [Static]
    [Export("didFailToRegisterForRemoteNotificationsWithError:")]
    void DidFailToRegisterForRemoteNotifications(NSError error);

    [Static]
    [Export("requestPermissionWithProvisional:completion:")]
    void RequestPermission(bool provisional, DTPPermissionCompletion completion);

    [Static]
    [Export("permissionStatusWithCompletion:")]
    void PermissionStatus(DTPPermissionCompletion completion);

    [Static]
    [Export("identifyWithExternalId:email:identityToken:")]
    void Identify([NullAllowed] string externalId, [NullAllowed] string email, [NullAllowed] string identityToken);

    [Static]
    [Export("logout")]
    void Logout();

    [Static]
    [Export("setMarketingOptIn:")]
    void SetMarketingOptIn(bool optIn);

    [Static]
    [Export("deleteLocalData")]
    void DeleteLocalData();

    [Static]
    [Export("useAsNotificationCenterDelegate")]
    void UseAsNotificationCenterDelegate();

    [Static]
    [Export("handleNotificationResponse:")]
    bool HandleNotificationResponse(UNNotificationResponse response);

    [Static]
    [Export("presentationOptionsForNotification:")]
    [return: NullAllowed]
    NSNumber PresentationOptions(UNNotification notification);
}
