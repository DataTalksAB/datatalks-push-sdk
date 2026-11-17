# The SDK looks up FirebaseMessaging.register() by reflection: it exists only from firebase-messaging 25.1.0.
-keepclassmembers class com.google.firebase.messaging.FirebaseMessaging {
    public *** register();
}
