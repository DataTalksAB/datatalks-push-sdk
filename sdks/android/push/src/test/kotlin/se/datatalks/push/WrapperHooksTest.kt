package se.datatalks.push

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.app.Application
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Process
import androidx.test.core.app.ApplicationProvider
import androidx.work.testing.WorkManagerTestInitHelper
import com.google.common.truth.Truth.assertThat
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
import org.robolectric.shadows.ShadowLog
import org.robolectric.shadows.ShadowLooper
import se.datatalks.push.internal.AcceptedIdentity
import se.datatalks.push.internal.NotificationOpenActivity
import se.datatalks.push.internal.PendingIdentity
import se.datatalks.push.internal.PermissionRequestActivity
import se.datatalks.push.internal.PushRuntime
import se.datatalks.push.internal.identityFingerprint
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Behaviour the wrappers (Capacitor, MAUI) rely on: links left to the app, a tap held for a late listener, and the permission result. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@LooperMode(LooperMode.Mode.PAUSED)
class WrapperHooksTest {
    private val context: Application = ApplicationProvider.getApplicationContext()

    @Before
    fun start() {
        WorkManagerTestInitHelper.initializeTestWorkManager(context)
        PushRuntime.resetForTests()
        registerLauncher(context, LAUNCHER)
    }

    @After
    fun clear() {
        DataTalksPush.setListener(null)
        PushRuntime.resetForTests()
    }

    @Test
    fun withOpenLinksOff_aTapOpensTheLauncher_AndHandsTheLinkToTheApp() {
        DataTalksPush.initialize(context, Contract.APP_KEY, DataTalksPushOptions(openLinks = false))
        drainBackground()
        val opened = recordOpens()

        val started = open("push-1", "https://example.com/tickets")

        assertThat(started.component!!.className).isEqualTo(LAUNCHER)
        ShadowLooper.idleMainLooper()
        assertThat(opened).containsExactly("https://example.com/tickets")
    }

    @Test
    fun openLinksOff_holdsForATapThatStartsTheAppBeforeInitialize() {
        DataTalksPush.initialize(context, Contract.APP_KEY, DataTalksPushOptions(openLinks = false))
        drainBackground()
        PushRuntime.resetForTests() // A new process, started by a tap before the app calls initialize.

        assertThat(open("push-1", "myapp://tickets/1042").component!!.className).isEqualTo(LAUNCHER)
    }

    @Test
    fun openLinks_isOnByDefault_AndTurnsBackOn() {
        DataTalksPush.initialize(context, Contract.APP_KEY, DataTalksPushOptions(openLinks = false))
        drainBackground()
        DataTalksPush.initialize(context, Contract.APP_KEY)
        drainBackground()

        assertThat(open("push-1", "myapp://tickets/1042").data.toString()).isEqualTo("myapp://tickets/1042")
    }

    @Test
    fun aTapBeforeAnyListener_reachesTheFirstListenerSet_OnlyTheNewestAndOnlyOnce() {
        open("push-1", "myapp://tickets/1")
        open("push-2", "myapp://tickets/2")
        ShadowLooper.idleMainLooper()

        val first = recordOpens()
        ShadowLooper.idleMainLooper()
        val second = recordOpens()
        ShadowLooper.idleMainLooper()

        assertThat(first).containsExactly("myapp://tickets/2")
        assertThat(second).isEmpty()
    }

    @Test
    fun aTapWithAListener_isNotHeldForTheNext() {
        val first = recordOpens()
        open("push-1", "myapp://tickets/1")
        ShadowLooper.idleMainLooper()
        val second = recordOpens()
        ShadowLooper.idleMainLooper()

        assertThat(first).containsExactly("myapp://tickets/1")
        assertThat(second).isEmpty()
    }

    @Test
    fun permissionStatus_isNotDeterminedUntilTheAppAsks() {
        notifications().setNotificationsEnabled(false)

        assertThat(DataTalksPush.permissionStatus(context)).isEqualTo(DataTalksPermission.NOT_DETERMINED)
    }

    @Test
    fun requestPermission_asksFromTheSdksActivity_AndEveryCallerHearsTheAnswer() {
        notifications().setNotificationsEnabled(false)
        val host = Robolectric.buildActivity(Activity::class.java).setup().get()
        val answers = mutableListOf<DataTalksPermission>()

        DataTalksPush.requestPermission(host) { answers += it }
        DataTalksPush.requestPermission(host) { answers += it }

        val request = shadowOf(host).nextStartedActivity
        assertThat(request.component!!.className).isEqualTo(PermissionRequestActivity::class.java.name)
        assertThat(shadowOf(host).nextStartedActivity).isNull() // One prompt for both callers.

        val prompt = Robolectric.buildActivity(PermissionRequestActivity::class.java, request).create().get()
        val asked = shadowOf(prompt).lastRequestedPermission
        assertThat(asked.requestedPermissions).asList().containsExactly(Manifest.permission.POST_NOTIFICATIONS)

        prompt.onRequestPermissionsResult(asked.requestCode, asked.requestedPermissions, intArrayOf(PackageManager.PERMISSION_GRANTED))

        assertThat(answers).containsExactly(DataTalksPermission.AUTHORIZED, DataTalksPermission.AUTHORIZED)
        assertThat(prompt.isFinishing).isTrue()
        drainBackground()
        assertThat(PushRuntime.get(context).store.permissionAsked).isTrue()
    }

    @Test
    fun aRefusal_isDenied_AndTheNextRequestAsksAgain() {
        notifications().setNotificationsEnabled(false)
        val host = Robolectric.buildActivity(Activity::class.java).setup().get()
        val answers = mutableListOf<DataTalksPermission>()

        DataTalksPush.requestPermission(host) { answers += it }
        val prompt = Robolectric.buildActivity(PermissionRequestActivity::class.java, shadowOf(host).nextStartedActivity).create().get()
        val asked = shadowOf(prompt).lastRequestedPermission
        prompt.onRequestPermissionsResult(asked.requestCode, asked.requestedPermissions, intArrayOf(PackageManager.PERMISSION_DENIED))
        DataTalksPush.requestPermission(host) { answers += it }

        assertThat(answers).containsExactly(DataTalksPermission.DENIED)
        assertThat(shadowOf(host).nextStartedActivity.component!!.className).isEqualTo(PermissionRequestActivity::class.java.name)
    }

    @Test
    fun aPromptThatEndsWithoutAnAnswer_reportsTheStatus() {
        notifications().setNotificationsEnabled(false)
        val host = Robolectric.buildActivity(Activity::class.java).setup().get()
        val answers = mutableListOf<DataTalksPermission>()

        DataTalksPush.requestPermission(host) { answers += it }
        val prompt = Robolectric.buildActivity(PermissionRequestActivity::class.java, shadowOf(host).nextStartedActivity).create()
        drainBackground()
        prompt.get().finish()
        prompt.destroy()

        assertThat(answers).containsExactly(DataTalksPermission.DENIED)
    }

    @Test
    fun aRequestWhileTheAppIsAway_answersWithTheStatus_AndTheNextRequestAsks() {
        notifications().setNotificationsEnabled(false)
        val host = Robolectric.buildActivity(Activity::class.java).setup().get()
        val answers = mutableListOf<DataTalksPermission>()
        setImportance(ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED)

        DataTalksPush.requestPermission(host) { answers += it }
        drainBackground()
        ShadowLooper.idleMainLooper()

        // No prompt was shown, so the app hasn't asked yet.
        assertThat(answers).containsExactly(DataTalksPermission.NOT_DETERMINED)
        assertThat(shadowOf(host).nextStartedActivity).isNull()
        assertThat(PushRuntime.get(context).store.permissionAsked).isFalse()

        setImportance(ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND)
        DataTalksPush.requestPermission(host)

        assertThat(shadowOf(host).nextStartedActivity.component!!.className).isEqualTo(PermissionRequestActivity::class.java.name)
    }

    @Test
    fun aPromptThatCannotStart_answersWithTheStatus_AndTheNextRequestAsks() {
        notifications().setNotificationsEnabled(false)
        val unstartable = Robolectric.buildActivity(UnstartableHost::class.java).setup().get()
        val answers = mutableListOf<DataTalksPermission>()

        DataTalksPush.requestPermission(unstartable) { answers += it }
        assertThat(answers).isEmpty() // Answered after the call returns, as a real prompt would be.
        drainBackground()
        ShadowLooper.idleMainLooper()

        // No prompt was shown, so the app hasn't asked yet.
        assertThat(answers).containsExactly(DataTalksPermission.NOT_DETERMINED)
        assertThat(PushRuntime.get(context).store.permissionAsked).isFalse()
        assertThat(ShadowLog.getLogsForTag("DataTalksPush").map { it.msg })
            .contains("The permission prompt couldn't start: ActivityNotFoundException")

        val host = Robolectric.buildActivity(Activity::class.java).setup().get()
        DataTalksPush.requestPermission(host)

        assertThat(shadowOf(host).nextStartedActivity.component!!.className).isEqualTo(PermissionRequestActivity::class.java.name)
    }

    @Test
    fun aGrantedPermission_answersWithoutAPrompt() {
        shadowOf(context).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val host = Robolectric.buildActivity(Activity::class.java).setup().get()
        val answers = mutableListOf<DataTalksPermission>()

        DataTalksPush.requestPermission(host) { answers += it }
        assertThat(answers).isEmpty() // Answered after the call returns, as a real prompt would be.
        ShadowLooper.idleMainLooper()

        assertThat(answers).containsExactly(DataTalksPermission.AUTHORIZED)
        assertThat(shadowOf(host).nextStartedActivity).isNull()
    }

    @Test
    @Config(sdk = [32])
    fun beforeAndroid13_thereIsNoPrompt_AndTheAnswerIsTheSwitch() {
        notifications().setNotificationsEnabled(false)
        val host = Robolectric.buildActivity(Activity::class.java).setup().get()
        val answers = mutableListOf<DataTalksPermission>()

        DataTalksPush.requestPermission(host) { answers += it }
        ShadowLooper.idleMainLooper()

        assertThat(answers).containsExactly(DataTalksPermission.DENIED)
        assertThat(shadowOf(host).nextStartedActivity).isNull()
    }

    @Test
    fun aRepeatedIdentify_answersTheListener_WithoutACall() {
        DataTalksPush.initialize(context, Contract.APP_KEY)
        drainBackground()
        val runtime = PushRuntime.get(context)
        val store = runtime.store
        store.installId = "3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f"
        val identity = PendingIdentity.Identify("member-1001", null, null)
        store.acceptedIdentity = AcceptedIdentity(identityFingerprint(store.installId!!, identity), runtime.sync.today(), true)
        val answers = mutableListOf<Boolean>()
        DataTalksPush.setListener(object : DataTalksPushListener {
            override fun onIdentityResult(result: DataTalksIdentityResult) {
                answers += result.verified
            }
        })

        DataTalksPush.identify("member-1001")
        drainBackground()
        ShadowLooper.idleMainLooper()

        assertThat(answers).containsExactly(true)
        assertThat(store.pendingIdentity).isNull()
    }

    private fun recordOpens(): MutableList<String?> {
        val opened = mutableListOf<String?>()
        DataTalksPush.setListener(object : DataTalksPushListener {
            override fun onNotificationOpened(deepLink: String?, data: JSONObject?) {
                opened += deepLink
            }
        })
        return opened
    }

    private fun open(uid: String, link: String?): Intent {
        val intent = Intent(context, NotificationOpenActivity::class.java)
            .putExtra(NotificationOpenActivity.EXTRA_UID, uid)
            .putExtra(NotificationOpenActivity.EXTRA_LINK, link)
        val activity = Robolectric.buildActivity(NotificationOpenActivity::class.java, intent).create().get()
        assertThat(activity.isFinishing).isTrue()
        return shadowOf(context).nextStartedActivity ?: shadowOf(activity).nextStartedActivity
    }

    private fun drainBackground() {
        val done = CountDownLatch(1)
        PushRuntime.get(context).execute { done.countDown() }
        check(done.await(10, TimeUnit.SECONDS))
    }

    private fun notifications() = shadowOf(context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)

    private fun setImportance(importance: Int) {
        val process = ActivityManager.RunningAppProcessInfo().also {
            it.pid = Process.myPid()
            it.importance = importance
        }
        shadowOf(context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).setProcesses(listOf(process))
    }

    /** A host whose activity starts fail, as on a device that blocks them. */
    class UnstartableHost : Activity() {
        override fun startActivity(intent: Intent) {
            throw ActivityNotFoundException("Blocked")
        }
    }

    private companion object {
        const val LAUNCHER = "se.datatalks.Launcher"
    }
}
