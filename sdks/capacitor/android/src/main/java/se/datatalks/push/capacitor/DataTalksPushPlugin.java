package se.datatalks.push.capacitor;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.os.Build;
import com.getcapacitor.JSObject;
import com.getcapacitor.Logger;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import java.util.List;
import org.json.JSONException;
import org.json.JSONObject;
import se.datatalks.push.DataTalksIdentityResult;
import se.datatalks.push.DataTalksMessage;
import se.datatalks.push.DataTalksMessagingService;
import se.datatalks.push.DataTalksPermission;
import se.datatalks.push.DataTalksPush;
import se.datatalks.push.DataTalksPushListener;
import se.datatalks.push.DataTalksPushOptions;

/**
 * Capacitor bridge to the Data Talks Android SDK. It has no logic of its own: each call forwards to {@link DataTalksPush},
 * and the SDK's listener callbacks become plugin events.
 */
@CapacitorPlugin(name = "DataTalksPush")
public class DataTalksPushPlugin extends Plugin {

    private static final String TAG = "DataTalksPush";
    private static final String MESSAGING_EVENT = "com.google.firebase.MESSAGING_EVENT";
    private static final String C2DM_RECEIVE = "com.google.android.c2dm.intent.RECEIVE";
    // Declared by Firebase itself, at the lowest priority, for apps without their own service.
    private static final String FIREBASE_DEFAULT_SERVICE = "com.google.firebase.messaging.FirebaseMessagingService";
    // Package prefix of Firebase's own receiver, which hands messages to the service.
    private static final String FIREBASE_PACKAGE = "com.google.firebase.";

    // The SDK holds one listener per process, and each bridge creates its own plugin instance. Only the newest may clear it.
    private static DataTalksPushPlugin current;

    private final DataTalksPushListener listener = new DataTalksPushListener() {
        @Override
        public void onNotificationOpened(String deepLink, JSONObject data) {
            JSObject event = new JSObject();
            event.put("deepLink", deepLink);
            putData(event, data);
            // Retained until the web app listens: a tap that launches the app arrives before its JavaScript runs.
            notifyListeners("notificationOpened", event, true);
        }

        @Override
        public void onMessageReceived(DataTalksMessage message) {
            JSObject event = new JSObject();
            event.put("uid", message.getUid());
            event.put("title", message.getTitle());
            event.put("body", message.getBody());
            event.put("imageUrl", message.getImageUrl());
            event.put("deepLink", message.getDeepLink());
            putData(event, message.getData());
            notifyListeners("messageReceived", event);
        }

        @Override
        public void onIdentityResult(DataTalksIdentityResult result) {
            JSObject event = new JSObject();
            event.put("verified", result.getVerified());
            event.put("errorCode", result.getErrorCode());
            event.put("errorDetail", result.getErrorDetail());
            notifyListeners("identityResult", event);
        }
    };

    @Override
    public void load() {
        // Listener first: a tap the SDK is holding is delivered now and retained in the plugin until the web app listens.
        setCurrent(this);
        DataTalksPush.setListener(listener);
        warnAboutOtherPushPlugins();

        String appKey = getConfig().getString("appKey");
        if (appKey == null || appKey.isEmpty()) {
            Logger.error(TAG, "capacitor.config has no plugins.DataTalksPush.appKey: the SDK stays off.", null);
            return;
        }

        DataTalksPushOptions options = new DataTalksPushOptions(getConfig().getString("baseUrl"), getConfig().getBoolean("openLinks", true));
        DataTalksPush.initialize(getContext(), appKey, options);
    }

    /**
     * Firebase delivers each message to a single service, so another push plugin's service also takes Data Talks pushes and
     * they never show. This can't be fixed at run time, so the other service is logged at startup (Capacitor logs only in
     * debug builds by default).
     */
    private void warnAboutOtherPushPlugins() {
        PackageManager packages = getContext().getPackageManager();
        String app = getContext().getPackageName();

        for (ResolveInfo resolved : queryServices(packages, new Intent(MESSAGING_EVENT).setPackage(app))) {
            String service = resolved.serviceInfo.name;
            if (service.equals(FIREBASE_DEFAULT_SERVICE) || handsMessagesToSdk(service)) continue;

            Logger.error(TAG, "Another service receives Firebase messages: " + service + ". Firebase gives each message to one "
                    + "service, so unless it forwards them to DataTalksPush.handleRemoteMessage, pushes from Data Talks never "
                    + "show. Remove the other push plugin, such as @capacitor/push-notifications.", null);
        }

        // Some SDKs, such as OneSignal, read the messages before Firebase does, with a broadcast receiver of their own.
        for (ResolveInfo resolved : queryReceivers(packages, new Intent(C2DM_RECEIVE).setPackage(app))) {
            String receiver = resolved.activityInfo.name;
            if (!receiver.startsWith(FIREBASE_PACKAGE)) {
                Logger.error(TAG, "Another push SDK receives Firebase messages: " + receiver + ". Pushes from Data Talks may never "
                        + "show, or show twice. Remove the other SDK, such as OneSignal.", null);
            }
        }
    }

    /** The SDK's own service, or an app service that extends it (see the Android SDK README): both forward Data Talks messages. */
    private boolean handsMessagesToSdk(String service) {
        try {
            return DataTalksMessagingService.class.isAssignableFrom(Class.forName(service, false, getContext().getClassLoader()));
        } catch (ClassNotFoundException | LinkageError e) {
            // A check for the log must never keep the SDK from starting.
            return false;
        }
    }

    @SuppressWarnings("deprecation")
    private static List<ResolveInfo> queryServices(PackageManager packages, Intent intent) {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                ? packages.queryIntentServices(intent, PackageManager.ResolveInfoFlags.of(0))
                : packages.queryIntentServices(intent, 0);
    }

    @SuppressWarnings("deprecation")
    private static List<ResolveInfo> queryReceivers(PackageManager packages, Intent intent) {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                ? packages.queryBroadcastReceivers(intent, PackageManager.ResolveInfoFlags.of(0))
                : packages.queryBroadcastReceivers(intent, 0);
    }

    @Override
    protected void handleOnDestroy() {
        // A tap while no bridge exists waits in the SDK for the next one.
        if (clearCurrent(this)) DataTalksPush.setListener(null);
    }

    @Override
    @PluginMethod
    public void checkPermissions(PluginCall call) {
        call.resolve(permissionResult(DataTalksPush.permissionStatus(getContext())));
    }

    @Override
    @PluginMethod
    public void requestPermissions(PluginCall call) {
        Activity activity = getActivity();
        if (activity == null) {
            call.reject("There is no activity to ask from.");
            return;
        }

        DataTalksPush.requestPermission(activity, permission -> call.resolve(permissionResult(permission)));
    }

    @PluginMethod
    public void identify(PluginCall call) {
        String externalId = call.getString("externalId");
        String email = call.getString("email");
        String identityToken = call.getString("identityToken");
        if (isEmpty(externalId) && isEmpty(email) && isEmpty(identityToken)) {
            call.reject("identify needs an externalId, an email or an identityToken.");
            return;
        }

        DataTalksPush.identify(externalId, email, identityToken);
        call.resolve();
    }

    @PluginMethod
    public void logout(PluginCall call) {
        DataTalksPush.logout();
        call.resolve();
    }

    @PluginMethod
    public void setMarketingOptIn(PluginCall call) {
        Boolean optIn = call.getBoolean("optIn");
        if (optIn == null) {
            call.reject("setMarketingOptIn needs optIn.");
            return;
        }

        DataTalksPush.setMarketingOptIn(optIn);
        call.resolve();
    }

    @PluginMethod
    public void deleteLocalData(PluginCall call) {
        DataTalksPush.deleteLocalData();
        call.resolve();
    }

    private static synchronized void setCurrent(DataTalksPushPlugin plugin) {
        current = plugin;
    }

    private static synchronized boolean clearCurrent(DataTalksPushPlugin plugin) {
        if (current != plugin) return false;
        current = null;
        return true;
    }

    /** Maps to Capacitor's states: prompt until the app asks, on Android 13 and later. */
    private static JSObject permissionResult(DataTalksPermission permission) {
        PermissionState state;
        switch (permission) {
            case AUTHORIZED:
                state = PermissionState.GRANTED;
                break;
            case DENIED:
                state = PermissionState.DENIED;
                break;
            default:
                state = PermissionState.PROMPT;
                break;
        }

        JSObject result = new JSObject();
        result.put("receive", state.toString());
        return result;
    }

    private static void putData(JSObject event, JSONObject data) {
        if (data == null) return;
        try {
            event.put("data", JSObject.fromJSONObject(data));
        } catch (JSONException e) {
            Logger.warn(TAG, "A push's data isn't an object, so the event goes without it.");
        }
    }

    private static boolean isEmpty(String value) {
        return value == null || value.isEmpty();
    }
}
