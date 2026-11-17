package se.datatalks.push

import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.testing.WorkManagerTestInitHelper
import com.google.common.truth.Truth.assertThat
import com.google.firebase.messaging.RemoteMessage
import org.json.JSONObject
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode
import org.robolectric.shadows.ShadowLooper
import se.datatalks.push.internal.NotificationOpenActivity
import se.datatalks.push.internal.NotificationRenderer
import se.datatalks.push.internal.PushMessage
import se.datatalks.push.internal.PushRuntime
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@LooperMode(LooperMode.Mode.PAUSED)
class RenderingAndCoexistenceTest {
    private val context: Application = ApplicationProvider.getApplicationContext()
    private val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    @Before
    fun start() {
        WorkManagerTestInitHelper.initializeTestWorkManager(context)
        PushRuntime.resetForTests()
    }

    @After
    fun clear() {
        DataTalksPush.setListener(null)
        PushRuntime.resetForTests()
    }

    @Test
    fun aPush_showsItsTitleAndBody_OnTheDefaultChannel() {
        render(mapOf("dt_v" to "1", "dt_uid" to "push-1", "dt_title" to "Match day", "dt_body" to "Gates open at 17:00"))

        val shown = shown("push-1")
        assertThat(shown.channelId).isEqualTo("datatalks_default")
        assertThat(shown.extras.getString(Notification.EXTRA_TITLE)).isEqualTo("Match day")
        assertThat(shown.extras.getString(Notification.EXTRA_TEXT)).isEqualTo("Gates open at 17:00")
        assertThat(shown.flags and Notification.FLAG_AUTO_CANCEL).isNotEqualTo(0)
        assertThat(manager.getNotificationChannel("datatalks_default").importance).isEqualTo(NotificationManager.IMPORTANCE_HIGH)
    }

    @Test
    fun aPushWithOnlyABody_isShown() {
        render(mapOf("dt_v" to "1", "dt_uid" to "push-1", "dt_body" to "Gates open"))

        assertThat(shown("push-1").extras.getString(Notification.EXTRA_TEXT)).isEqualTo("Gates open")
    }

    @Test
    fun aPushWithNothingToShow_isNotShown() {
        render(mapOf("dt_v" to "1", "dt_uid" to "push-1"))

        assertThat(manager.activeNotifications).isEmpty()
    }

    @Test
    fun aRequestedChannel_isUsed_OnlyWhenItExists() {
        manager.createNotificationChannel(NotificationChannel("offers", "Offers", NotificationManager.IMPORTANCE_DEFAULT))

        render(mapOf("dt_v" to "1", "dt_uid" to "push-1", "dt_title" to "A", "dt_channel" to "offers"))
        render(mapOf("dt_v" to "1", "dt_uid" to "push-2", "dt_title" to "B", "dt_channel" to "missing"))

        assertThat(shown("push-1").channelId).isEqualTo("offers")
        assertThat(shown("push-2").channelId).isEqualTo("datatalks_default")
    }

    @Test
    fun aCollapseKey_makesTheNewerPushReplaceTheOlder() {
        render(mapOf("dt_v" to "1", "dt_uid" to "push-1", "dt_title" to "First", "dt_collapse" to "matchday"))
        render(mapOf("dt_v" to "1", "dt_uid" to "push-2", "dt_title" to "Second", "dt_collapse" to "matchday"))
        render(mapOf("dt_v" to "1", "dt_uid" to "push-3", "dt_title" to "Other"))

        assertThat(manager.activeNotifications).hasLength(2)
        assertThat(shown("matchday").extras.getString(Notification.EXTRA_TITLE)).isEqualTo("Second")
    }

    @Test
    fun aPicture_makesABigPicture_AndAFailedOneDoesNotStopThePush() {
        val picture = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888)
        NotificationRenderer(context) { picture }.show(message(mapOf("dt_v" to "1", "dt_uid" to "push-1", "dt_title" to "A", "dt_image" to "https://cdn.example.com/a.jpg")))
        NotificationRenderer(context) { null }.show(message(mapOf("dt_v" to "1", "dt_uid" to "push-2", "dt_title" to "B", "dt_body" to "C", "dt_image" to "https://cdn.example.com/b.jpg")))

        assertThat(shown("push-1").extras.getString(Notification.EXTRA_TEMPLATE)).isEqualTo("android.app.Notification\$BigPictureStyle")
        assertThat(shown("push-2").extras.getString(Notification.EXTRA_TEMPLATE)).isEqualTo("android.app.Notification\$BigTextStyle")
    }

    @Test
    fun theAppsLook_comesWithThePush_ColourAndLargeIcon() {
        val logo = Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888)
        val picture = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888)
        val loaded = mutableListOf<String>()
        NotificationRenderer(context, { url -> loaded += url; logo }) { picture }.show(
            message(
                mapOf(
                    "dt_v" to "1", "dt_uid" to "push-1", "dt_title" to "A", "dt_image" to "https://cdn.example.com/a.jpg",
                    "dt_color" to "#F35625", "dt_large_icon" to "https://cdn.example.com/logo.png",
                ),
            ),
        )

        val shown = shown("push-1")
        assertThat(shown.color).isEqualTo(0xFFF35625.toInt())
        assertThat(loaded).containsExactly("https://cdn.example.com/logo.png")
        assertThat(shown.getLargeIcon()).isNotNull()
        assertThat(shown.extras.getString(Notification.EXTRA_TEMPLATE)).isEqualTo("android.app.Notification\$BigPictureStyle")
    }

    @Test
    fun aColourThePushCantCarry_andAMissingIcon_leaveTheDefaults() {
        NotificationRenderer(context, { null }) { null }.show(
            message(mapOf("dt_v" to "1", "dt_uid" to "push-1", "dt_title" to "A", "dt_color" to "orange", "dt_large_icon" to "https://cdn.example.com/gone.png")),
        )
        NotificationRenderer(context, { error("nothing to load") }) { null }.show(message(mapOf("dt_v" to "1", "dt_uid" to "push-2", "dt_title" to "B")))

        assertThat(shown("push-1").color).isEqualTo(Notification.COLOR_DEFAULT)
        assertThat(shown("push-1").getLargeIcon()).isNull()
        assertThat(shown("push-2").getLargeIcon()).isNull()
    }

    @Test
    fun aLargeIconThatFails_doesNotStopThePush() {
        NotificationRenderer(context, { throw IllegalStateException("broken") }) { null }.show(
            message(mapOf("dt_v" to "1", "dt_uid" to "push-1", "dt_title" to "A", "dt_large_icon" to "https://cdn.example.com/logo.png")),
        )

        assertThat(shown("push-1").extras.getString(Notification.EXTRA_TITLE)).isEqualTo("A")
        assertThat(shown("push-1").getLargeIcon()).isNull()
    }

    @Test
    fun aTap_opensThroughTheSdksActivity_WithTheLinkAndData() {
        render(mapOf("dt_v" to "1", "dt_uid" to "push-1", "dt_title" to "A", "dt_link" to "https://example.com/tickets", "dt_data" to """{"ticket_id":"T-1042"}"""))

        val intent = shadowOf(shown("push-1").contentIntent).savedIntent

        assertThat(intent.component!!.className).isEqualTo(NotificationOpenActivity::class.java.name)
        assertThat(intent.getStringExtra(NotificationOpenActivity.EXTRA_LINK)).isEqualTo("https://example.com/tickets")
        assertThat(shadowOf(shown("push-1").contentIntent).isActivity).isTrue()
        assertThat(shadowOf(shown("push-1").contentIntent).isImmutable).isTrue()
    }

    @Test
    fun anOpen_reportsToTheApp_QueuesTheEvent_AndOpensAnHttpsLinkThroughTheSystem() {
        val opened = mutableListOf<Pair<String?, JSONObject?>>()
        DataTalksPush.setListener(object : DataTalksPushListener {
            override fun onNotificationOpened(deepLink: String?, data: JSONObject?) {
                opened += deepLink to data
            }
        })

        val started = open("push-1", "https://example.com/tickets", """{"ticket_id":"T-1042"}""")

        assertThat(started.action).isEqualTo(Intent.ACTION_VIEW)
        assertThat(started.data).isEqualTo(Uri.parse("https://example.com/tickets"))
        assertThat(started.`package`).isNull()
        drainBackground()
        ShadowLooper.idleMainLooper()
        assertThat(opened.single().first).isEqualTo("https://example.com/tickets")
        assertThat(opened.single().second!!.getString("ticket_id")).isEqualTo("T-1042")
        val events = PushRuntime.get(context).store.pendingEvents(System.currentTimeMillis())
        assertThat(events.map { it.type to it.uid }).containsExactly("open" to "push-1", "click" to "push-1").inOrder()
        assertThat(events.last().link).isEqualTo("https://example.com/tickets")
    }

    @Test
    fun anOpenWithoutALink_orWithAnEmptyOne_isAnOpenOnly() {
        registerLauncher(context, "se.datatalks.Launcher")

        open("push-1", null, null)
        open("push-2", "", null)
        drainBackground()

        val events = PushRuntime.get(context).store.pendingEvents(System.currentTimeMillis())
        assertThat(events.map { it.type to it.uid }).containsExactly("open" to "push-1", "open" to "push-2").inOrder()
    }

    @Test
    fun aPushTheSdkShows_isADelivery_AndOneItCantShow_isNot() {
        DataTalksPush.handleRemoteMessage(context, RemoteMessage.Builder("sender").setData(mapOf("dt_v" to "1", "dt_uid" to "push-1", "dt_title" to "A")).build())
        DataTalksPush.handleRemoteMessage(context, RemoteMessage.Builder("sender").setData(mapOf("dt_v" to "1", "dt_uid" to "push-2")).build())
        shadowOf(manager).setNotificationsEnabled(false)
        DataTalksPush.handleRemoteMessage(context, RemoteMessage.Builder("sender").setData(mapOf("dt_v" to "1", "dt_uid" to "push-3", "dt_title" to "C")).build())

        val events = PushRuntime.get(context).store.pendingEvents(System.currentTimeMillis())
        assertThat(events.map { it.type to it.uid }).containsExactly("delivery" to "push-1")
    }

    @Test
    fun anAppLink_staysInsideTheApp() {
        val started = open("push-1", "myapp://tickets/1042", null)

        assertThat(started.`package`).isEqualTo(context.packageName)
    }

    @Test
    fun anOpenWithoutALink_opensTheLauncher() {
        registerLauncher(context, "se.datatalks.Launcher")

        val started = open("push-1", null, null)

        assertThat(started.component!!.className).isEqualTo("se.datatalks.Launcher")
    }

    @Test
    fun handleRemoteMessage_takesOurs_AndLeavesTheAppsOwnAlone() {
        val received = mutableListOf<DataTalksMessage>()
        DataTalksPush.setListener(object : DataTalksPushListener {
            override fun onMessageReceived(message: DataTalksMessage) {
                received += message
            }
        })

        val ours = RemoteMessage.Builder("fixture").setData(mapOf("dt_v" to "1", "dt_uid" to "push-1", "dt_title" to "Ours", "dt_data" to """{"a":"b"}""")).build()
        val theirs = RemoteMessage.Builder("fixture").setData(mapOf("title" to "Theirs")).build()

        assertThat(DataTalksPush.handleRemoteMessage(context, ours)).isTrue()
        assertThat(DataTalksPush.handleRemoteMessage(context, theirs)).isFalse()

        assertThat(manager.activeNotifications).hasLength(1)
        ShadowLooper.idleMainLooper()
        assertThat(received.single().title).isEqualTo("Ours")
        assertThat(received.single().data!!.getString("a")).isEqualTo("b")
    }

    @Test
    fun onNewRegistration_storesTheValue_AndSchedulesTheSyncOnceTheAppIsStarted() {
        DataTalksPush.onNewRegistration(context, "$FID:APA91bFIXTURE")
        drainBackground()
        val runtime = PushRuntime.get(context)
        assertThat(runtime.store.pushValue!!.value).isEqualTo("$FID:APA91bFIXTURE")
        assertThat(runtime.store.pushValue!!.type).isEqualTo("fcm_token")
        assertThat(scheduledSyncs()).isEmpty()

        DataTalksPush.initialize(context, Contract.APP_KEY)
        drainBackground()
        assertThat(scheduledSyncs()).hasSize(1)
    }

    @Test
    fun aMalformedKey_leavesTheSdkOff() {
        DataTalksPush.initialize(context, "not-a-key")

        assertThat(PushRuntime.current()).isNull()
    }

    @Test
    fun callsBeforeInitialize_doNothing_AndDoNotThrow() {
        DataTalksPush.identify(externalId = "member-1001")
        DataTalksPush.logout()
        DataTalksPush.setMarketingOptIn(true)
        DataTalksPush.deleteLocalData()

        assertThat(PushRuntime.current()).isNull()
    }

    @Test
    fun deleteLocalData_twice_keepsTheDeleteOfTheInstall() {
        DataTalksPush.initialize(context, Contract.APP_KEY)
        drainBackground()
        val runtime = PushRuntime.get(context)
        runtime.execute {
            runtime.store.installId = INSTALL_ID
            runtime.store.deviceSecret = Contract.DEVICE_SECRET
        }

        DataTalksPush.deleteLocalData()
        DataTalksPush.deleteLocalData()
        drainBackground()

        assertThat(runtime.store.pendingDelete!!.installId).isEqualTo(INSTALL_ID)
        assertThat(runtime.store.installId).isNull()
        assertThat(runtime.store.appKey).isNull()
    }

    private fun render(values: Map<String, String>) {
        NotificationRenderer(context) { null }.show(message(values))
    }

    private fun message(values: Map<String, String>) = PushMessage.from(values)!!

    private fun shown(tag: String): Notification = manager.activeNotifications.single { it.tag == tag }.notification

    private fun open(uid: String, link: String?, data: String?): Intent {
        val intent = Intent(context, NotificationOpenActivity::class.java)
            .putExtra(NotificationOpenActivity.EXTRA_UID, uid)
            .putExtra(NotificationOpenActivity.EXTRA_LINK, link)
            .putExtra(NotificationOpenActivity.EXTRA_DATA, data)
        val activity = Robolectric.buildActivity(NotificationOpenActivity::class.java, intent).create().get()
        assertThat(activity.isFinishing).isTrue()
        return shadowOf(context).nextStartedActivity ?: shadowOf(activity).nextStartedActivity
    }

    private fun drainBackground() {
        val done = CountDownLatch(1)
        PushRuntime.get(context).execute { done.countDown() }
        check(done.await(10, TimeUnit.SECONDS))
    }

    private fun scheduledSyncs(): List<WorkInfo> =
        WorkManager.getInstance(context).getWorkInfosForUniqueWork("se.datatalks.push.sync").get().filter { it.state == WorkInfo.State.ENQUEUED }
}
