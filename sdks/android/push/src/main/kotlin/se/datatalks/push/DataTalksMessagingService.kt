package se.datatalks.push

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * The SDK's `FirebaseMessagingService`, merged into the app's manifest. If the app declares its own service, Android
 * calls that one instead: extend this class, or forward to [DataTalksPush.handleRemoteMessage] and
 * [DataTalksPush.onNewRegistration].
 */
open class DataTalksMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        DataTalksPush.onNewRegistration(this, token)
    }

    // Added in firebase-messaging 25.1.0. Older versions never call it, and the class still loads.
    override fun onRegistered(installationId: String) {
        DataTalksPush.onNewRegistration(this, installationId)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        DataTalksPush.handleRemoteMessage(this, message)
    }
}
