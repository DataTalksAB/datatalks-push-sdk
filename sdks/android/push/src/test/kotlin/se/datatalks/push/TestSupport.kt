package se.datatalks.push

import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.ResolveInfo
import androidx.test.core.app.ApplicationProvider
import okhttp3.mockwebserver.MockWebServer
import org.robolectric.Shadows.shadowOf
import se.datatalks.push.internal.DeviceFacts
import se.datatalks.push.internal.PushStore
import se.datatalks.push.internal.PushSync
import se.datatalks.push.internal.PushValue
import se.datatalks.push.internal.PushValueLookup
import se.datatalks.push.internal.ValueCrypto

/** Robolectric has no Android Keystore. This fake transforms values, so a test can check they never reach the disk in clear. */
internal object MarkingCrypto : ValueCrypto {
    private const val MARK = "encrypted:"

    override fun encrypt(plain: String) = MARK + plain.reversed()

    override fun decrypt(stored: String) = stored.removePrefix(MARK).reversed()
}

/** Registers [name] as the app's launcher activity, which a tap opens when there is no link to open. */
internal fun registerLauncher(context: Context, name: String) {
    val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setPackage(context.packageName)
    @Suppress("DEPRECATION") // Its replacement needs the activity registered as a component first.
    shadowOf(context.packageManager).addResolveInfoForIntent(launcher, ResolveInfo().apply {
        activityInfo = ActivityInfo().apply {
            packageName = context.packageName
            this.name = name
        }
    })
}

internal const val FID = "cXa1B2c3D4e5F6g7H8i9J0"
internal const val INSTALL_ID = "3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f"

/** A [PushSync] against a mock server and a fresh store, with the clock and the FCM value controlled by the test. */
internal class SyncHarness {
    val context: Context = ApplicationProvider.getApplicationContext()
    val server = MockWebServer().apply { start() }
    val store = PushStore(context, MarkingCrypto)
    val identityResults = mutableListOf<DataTalksIdentityResult>()
    var lookup: PushValueLookup = PushValueLookup.Found(PushValue(FID, PushValue.TYPE_FID))
    var now = 1_800_000_000_000L
    val sync = PushSync(store, { lookup }, DeviceFacts(context, store), identityResults::add, { now })

    init {
        store.appKey = Contract.APP_KEY
        store.baseUrl = server.url("/v1").toString().trimEnd('/')
        store.configExpiresAt = Long.MAX_VALUE
    }

    fun stop() = server.shutdown()
}
