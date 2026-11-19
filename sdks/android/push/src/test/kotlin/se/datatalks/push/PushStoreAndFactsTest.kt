package se.datatalks.push

import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import se.datatalks.push.internal.AppKeys
import se.datatalks.push.internal.DeviceFacts
import se.datatalks.push.internal.FcmMode
import se.datatalks.push.internal.PendingDelete
import se.datatalks.push.internal.PendingIdentity
import se.datatalks.push.internal.PushEvent
import se.datatalks.push.internal.PushStore
import se.datatalks.push.internal.PushValue
import se.datatalks.push.internal.ValueCrypto

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PushStoreAndFactsTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val store = PushStore(context, MarkingCrypto)

    @Test
    fun secrets_neverReachTheDiskAsTheyAre() {
        store.appKey = Contract.APP_KEY
        store.installId = INSTALL_ID
        store.deviceSecret = Contract.DEVICE_SECRET
        store.updatePushValue(PushValue(FID, PushValue.TYPE_FID))
        store.pendingIdentity = PendingIdentity.Identify("member-1001", "anna@example.com", Contract.IDENTITY_TOKEN)
        store.pendingDelete = PendingDelete(Contract.APP_KEY, null, INSTALL_ID, Contract.DEVICE_SECRET)

        val onDisk = context.getSharedPreferences("se.datatalks.push", Context.MODE_PRIVATE).all.values.joinToString()

        for (secret in listOf(Contract.APP_KEY, INSTALL_ID, Contract.DEVICE_SECRET, FID, "member-1001", "anna@example.com", Contract.IDENTITY_TOKEN)) {
            assertThat(onDisk).doesNotContain(secret)
        }
    }

    @Test
    fun aNewStoreOnTheSameFile_readsTheValuesBack() {
        store.deviceSecret = Contract.DEVICE_SECRET
        store.updatePushValue(PushValue(FID, PushValue.TYPE_FID))
        store.pendingIdentity = PendingIdentity.Identify(null, "anna@example.com", null)

        val again = PushStore(context, MarkingCrypto)

        assertThat(again.deviceSecret).isEqualTo(Contract.DEVICE_SECRET)
        assertThat(again.pushValue).isEqualTo(PushValue(FID, PushValue.TYPE_FID))
        assertThat(again.pendingIdentity).isEqualTo(PendingIdentity.Identify(null, "anna@example.com", null))
    }

    @Test
    fun aValueTheKeystoreCantEncrypt_livesOnlyInMemory() {
        val broken = PushStore(context, object : ValueCrypto {
            override fun encrypt(plain: String): String = throw IllegalStateException("no keystore")

            override fun decrypt(stored: String): String = throw IllegalStateException("no keystore")
        })

        broken.deviceSecret = Contract.DEVICE_SECRET

        assertThat(broken.deviceSecret).isEqualTo(Contract.DEVICE_SECRET)
        assertThat(PushStore(context, MarkingCrypto).deviceSecret).isNull()
    }

    @Test
    fun aValueRestoredFromABackup_readsAsAbsent() {
        store.installId = INSTALL_ID

        val otherDevice = PushStore(context, object : ValueCrypto {
            override fun encrypt(plain: String) = plain

            override fun decrypt(stored: String): String = throw javax.crypto.AEADBadTagException()
        })

        assertThat(otherDevice.installId).isNull()
    }

    @Test
    fun updatePushValue_saysWhetherItChanged() {
        assertThat(store.updatePushValue(PushValue(FID, PushValue.TYPE_FID))).isTrue()
        assertThat(store.pushValueChanged).isTrue()
        store.markRegistered(1, "authorized")
        assertThat(store.pushValueChanged).isFalse()

        assertThat(store.updatePushValue(PushValue(FID, PushValue.TYPE_FID))).isFalse()
        assertThat(store.pushValueChanged).isFalse()

        assertThat(store.updatePushValue(PushValue(FID, PushValue.TYPE_TOKEN))).isTrue()
    }

    @Test
    fun theEventQueue_keepsTheNewest200_EachWithItsOwnId() {
        repeat(205) { store.queueEvent(PushEvent.DELIVERY, "push-$it", NOW + it) }

        val events = store.pendingEvents(NOW)

        assertThat(events).hasSize(200)
        assertThat(events.first().uid).isEqualTo("push-5")
        assertThat(events.last().uid).isEqualTo("push-204")
        assertThat(events.map { it.eventId }.toSet()).hasSize(200)
    }

    @Test
    fun anEvent_KeepsItsLink_AndANewStoreReadsItBack() {
        store.queueEvent(PushEvent.CLICK, "push-1", NOW, "https://example.com/tickets")

        val event = PushStore(context, MarkingCrypto).pendingEvents(NOW).single()

        assertThat(event.type).isEqualTo("click")
        assertThat(event.link).isEqualTo("https://example.com/tickets")
        assertThat(event.occurredAt).isEqualTo(NOW)
    }

    @Test
    fun anEventOlderThan30Days_IsDropped_AndAnsweredOnesAreForgotten() {
        store.queueEvent(PushEvent.OPEN, "old", NOW - THIRTY_ONE_DAYS)
        store.queueEvent(PushEvent.OPEN, "answered", NOW)
        store.queueEvent(PushEvent.OPEN, "waiting", NOW)
        val answered = store.pendingEvents(NOW).single { it.uid == "answered" }.eventId

        store.removeEvents(setOf(answered))

        assertThat(store.pendingEvents(NOW).map { it.uid }).containsExactly("waiting")
    }

    @Test
    fun opensKeptBeforeContract110_BecomeOpenEvents() {
        context.getSharedPreferences("se.datatalks.push", Context.MODE_PRIVATE).edit()
            .putString("open_events", """[{"uid":"push-1","opened_at":$NOW}]""")
            .commit()
        store.queueEvent(PushEvent.DELIVERY, "push-2", NOW + 1)

        val events = store.pendingEvents(NOW)

        assertThat(events.map { it.type to it.uid }).containsExactly("open" to "push-1", "delivery" to "push-2").inOrder()
        assertThat(context.getSharedPreferences("se.datatalks.push", Context.MODE_PRIVATE).contains("open_events")).isFalse()
    }

    @Test
    fun droppingTheInstall_DropsItsEvents() {
        store.installId = INSTALL_ID
        store.queueEvent(PushEvent.OPEN, "push-1", NOW)

        store.dropInstall()

        assertThat(store.hasEvents).isFalse()
    }

    @Test
    fun wipe_removesEverything() {
        store.appKey = Contract.APP_KEY
        store.installId = INSTALL_ID
        store.queueEvent(PushEvent.OPEN, "push-1", 1)

        store.wipe()

        assertThat(store.appKey).isNull()
        assertThat(store.installId).isNull()
        assertThat(store.hasEvents).isFalse()
    }

    @Test
    fun appKeys_chooseTheHost_AndAnythingElseIsNoKey() {
        val body = "Fixture0AppKey00000000000000000000".take(32)
        assertThat(AppKeys.baseUrl("dtpk_prd_$body")).isEqualTo("https://push.datatalks.se/v1")
        assertThat(AppKeys.baseUrl("dtpk_stg_$body")).isEqualTo("https://push.staging.datatalks.se/v1")
        assertThat(AppKeys.baseUrl("dtpk_prd_live_$body")).isEqualTo("https://push.datatalks.se/v1")
        assertThat(AppKeys.baseUrl("dtpk_prd_test_$body")).isEqualTo("https://push.datatalks.se/v1")
        assertThat(AppKeys.baseUrl("dtpk_stg_live_$body")).isEqualTo("https://push.staging.datatalks.se/v1")
        assertThat(AppKeys.baseUrl("dtsk_prd_$body")).isNull()
        assertThat(AppKeys.baseUrl("dtpk_prd_live_short")).isNull()
        assertThat(AppKeys.baseUrl("")).isNull()
    }

    @Test
    fun metadata_isCutToTheContractsLengths() {
        assertThat(DeviceFacts.cut("abcdef", 4)).isEqualTo("abcd")
        assertThat(DeviceFacts.cut("abc", 4)).isEqualTo("abc")
        // A surrogate pair that doesn't fit is dropped whole, never split in half.
        assertThat(DeviceFacts.cut("abc😀", 4)).isEqualTo("abc")
    }

    @Test
    @Config(sdk = [32])
    fun permission_beforeAndroid13_isOnlyOnOrOff() {
        val facts = DeviceFacts(context, store)
        assertThat(facts.permission()).isEqualTo("authorized")

        notifications().setNotificationsEnabled(false)
        assertThat(facts.permission()).isEqualTo("denied")
    }

    @Test
    @Config(sdk = [33])
    fun permission_fromAndroid13_isNotDeterminedUntilAsked() {
        val facts = DeviceFacts(context, store)
        notifications().setNotificationsEnabled(false)
        assertThat(facts.permission()).isEqualTo("not_determined")

        store.permissionAsked = true
        assertThat(facts.permission()).isEqualTo("denied")

        notifications().setNotificationsEnabled(true)
        assertThat(facts.permission()).isEqualTo("authorized")
    }

    @Test
    fun theMode_followsTheAppsManifestFlag() {
        assertThat(FcmMode.typeOf(context)).isEqualTo(PushValue.TYPE_TOKEN)

        setFlag(true)
        assertThat(FcmMode.usesFid(context)).isTrue()
        assertThat(FcmMode.typeOf(context)).isEqualTo(PushValue.TYPE_FID)

        setFlag(false)
        assertThat(FcmMode.usesFid(context)).isFalse()
    }

    private fun setFlag(on: Boolean) {
        val manager = RuntimeEnvironment.getApplication().packageManager
        val info = shadowOf(manager).getInternalMutablePackageInfo(context.packageName)
        info.applicationInfo!!.metaData = Bundle().apply { putBoolean(FcmMode.FLAG, on) }
        check(manager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA).metaData.containsKey(FcmMode.FLAG))
    }

    private fun notifications() = shadowOf(context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)

    private companion object {
        const val NOW = 1_800_000_000_000L
        const val THIRTY_ONE_DAYS = 31L * 24 * 60 * 60 * 1_000
    }
}
