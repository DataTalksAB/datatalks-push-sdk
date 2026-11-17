package se.datatalks.push

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.common.truth.Truth.assertThat
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import se.datatalks.push.internal.DeviceFacts
import se.datatalks.push.internal.KeystoreCrypto
import se.datatalks.push.internal.PendingDelete
import se.datatalks.push.internal.PendingIdentity
import se.datatalks.push.internal.PushStore
import se.datatalks.push.internal.PushSync
import se.datatalks.push.internal.PushValue
import se.datatalks.push.internal.PushValueLookup
import se.datatalks.push.internal.SyncOutcome
import java.util.UUID

/**
 * On a device, with the real Android Keystore. The flow runs against a real ingress when the run says where one is:
 * `connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.baseUrl=http://10.0.2.2:<port>/v1 ...appKey=<key>`.
 */
@RunWith(AndroidJUnit4::class)
class DeviceFlowTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    @Test
    fun theKeystore_encryptsAndReadsBack() {
        val secret = "Fixture0Secret000000000000000000"

        val stored = KeystoreCrypto.encrypt(secret)

        assertThat(stored).doesNotContain(secret)
        assertThat(KeystoreCrypto.encrypt(secret)).isNotEqualTo(stored)
        assertThat(KeystoreCrypto.decrypt(stored)).isEqualTo(secret)
    }

    @Test
    fun theStore_keepsItsValuesAcrossInstances() {
        val store = PushStore(context)
        store.wipe()
        store.deviceSecret = "Fixture0Secret000000000000000000"

        assertThat(PushStore(context).deviceSecret).isEqualTo("Fixture0Secret000000000000000000")

        store.wipe()
    }

    @Test
    fun theDeviceFlow_againstARealIngress() {
        val arguments = InstrumentationRegistry.getArguments()
        val baseUrl = arguments.getString("baseUrl")
        val appKey = arguments.getString("appKey")
        assumeTrue("Needs baseUrl and appKey", baseUrl != null && appKey != null)

        val store = PushStore(context)
        store.wipe()
        store.appKey = appKey
        store.baseUrl = baseUrl

        val identities = mutableListOf<DataTalksIdentityResult>()
        val fid = "fixtureFid" + UUID.randomUUID().toString().replace("-", "").take(12)
        val sync = PushSync(store, { PushValueLookup.Found(PushValue(fid, PushValue.TYPE_FID)) }, DeviceFacts(context, store), { identities += it })

        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)
        val installId = store.installId!!
        val secret = store.deviceSecret!!
        assertThat(secret).matches("^[0-9A-Za-z]{32}$")

        store.pendingOptIn = false
        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)
        assertThat(store.pendingOptIn).isNull()

        store.pendingIdentity = PendingIdentity.Identify(null, "anna@example.com", null)
        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)
        assertThat(identities.single().errorCode).isEqualTo(arguments.getString("identifyError"))

        store.pendingIdentity = PendingIdentity.Logout
        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)
        assertThat(store.pendingIdentity).isNull()
        assertThat(store.installId).isEqualTo(installId)

        store.pendingDelete = PendingDelete(appKey!!, baseUrl, installId, secret)
        store.appKey = null
        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)
        assertThat(store.pendingDelete).isNull()

        store.wipe()
    }
}
