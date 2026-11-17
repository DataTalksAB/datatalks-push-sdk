package se.datatalks.push.sample

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import se.datatalks.push.DataTalksPermission
import se.datatalks.push.DataTalksPush

private val Orange = Color(0xFFF35625)
private val Indigo = Color(0xFF1F1451)
private val Page = Color(0xFFEEF1F8)
private val Muted = Color(0xFF5E6278)
private val OrangeBorder = BorderStroke(1.5.dp, Orange)

/**
 * The sample screen: start the SDK with a key, request the permission, identify (optionally with a token from the
 * portal's "Test a token"), log out, set consent, delete local data, and list what the SDK reports.
 */
class MainActivity : ComponentActivity() {
    private var permission by mutableStateOf<DataTalksPermission?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Light status bar icons over the indigo header.
        enableEdgeToEdge(statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT))

        // For a scripted run: adb shell am start -n <app>/se.datatalks.push.sample.MainActivity --es app_key <key> --es base_url <url>
        val settings = SampleSettings(this)
        intent.getStringExtra("app_key")?.let { key ->
            settings.appKey = key
            settings.baseUrl = intent.getStringExtra("base_url")
            SampleApplication.start(this, key, settings.baseUrl)
        }

        setContent {
            MaterialTheme(colorScheme = lightColorScheme(primary = Orange, onPrimary = Color.White, secondary = Indigo, background = Page)) {
                SandboxScreen(settings)
            }
        }
    }

    // The permission can change in the system settings while the app is in the background.
    override fun onResume() {
        super.onResume()
        permission = DataTalksPush.permissionStatus(this)
    }

    @Composable
    private fun SandboxScreen(settings: SampleSettings) {
        Column(
            Modifier
                .fillMaxSize()
                .background(Page)
                .verticalScroll(rememberScrollState())
                .imePadding(),
        ) {
            Header()
            Column(
                Modifier
                    .navigationBarsPadding()
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Section("App") { StartSection(settings) }
                Section("User") { IdentitySection() }
                Section("Device") { ConsentSection() }
                Section("Events") { EventsSection() }
            }
        }
    }

    @Composable
    private fun Header() {
        Row(
            Modifier
                .fillMaxWidth()
                .background(Indigo)
                .statusBarsPadding()
                .padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Image(painterResource(R.drawable.datatalks_mark), contentDescription = null, Modifier.size(40.dp))
            Column(Modifier.weight(1f)) {
                Text("Data Talks", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                Text("Push SDK demo · Native Android", color = Color.White.copy(alpha = 0.7f), fontSize = 13.sp)
            }
            Text(
                "SANDBOX",
                Modifier
                    .background(Color.White, RoundedCornerShape(50))
                    .padding(horizontal = 10.dp, vertical = 4.dp),
                color = Indigo,
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 1.5.sp,
            )
        }
    }

    @Composable
    private fun Section(title: String, content: @Composable ColumnScope.() -> Unit) {
        Card(
            Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(12.dp),
            colors = CardDefaults.cardColors(containerColor = Color.White),
        ) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(title.uppercase(), color = Indigo, fontSize = 12.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
                content()
            }
        }
    }

    @Composable
    private fun StartSection(settings: SampleSettings) {
        var key by remember { mutableStateOf(settings.appKey.orEmpty()) }
        var baseUrl by remember { mutableStateOf(settings.baseUrl.orEmpty()) }

        Field("App key", key) { key = it.trim() }
        Hint(keyDescription(key))
        Field("Host, only for a local ingress", baseUrl) { baseUrl = it.trim() }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = {
                settings.appKey = key
                settings.baseUrl = baseUrl.ifEmpty { null }
                SampleApplication.start(this@MainActivity, key, settings.baseUrl)
            }) {
                Text("Register")
            }

            OutlinedButton(border = OrangeBorder, onClick = {
                DataTalksPush.requestPermission(this@MainActivity) {
                    permission = it
                    SampleEvents.add("Permission: ${it.value}")
                }
            }) {
                Text("Ask for permission")
            }
        }
        Hint("Permission: ${permission?.value ?: "unknown"}")
    }

    @Composable
    private fun IdentitySection() {
        var externalId by remember { mutableStateOf("") }
        var email by remember { mutableStateOf("") }
        var token by remember { mutableStateOf("") }

        Field("External id", externalId) { externalId = it }
        Field("Email", email) { email = it }
        Field("Identity token", token) { token = it.trim() }
        Hint("Paste a token from the portal's Test a token, or leave it empty for an unverified identify.")
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = { DataTalksPush.identify(externalId.ifEmpty { null }, email.ifEmpty { null }, token.ifEmpty { null }) }) {
                Text("Identify")
            }

            OutlinedButton(border = OrangeBorder, onClick = { DataTalksPush.logout() }) {
                Text("Log out")
            }
        }
    }

    @Composable
    private fun ConsentSection() {
        var optIn by remember { mutableStateOf(true) }

        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Switch(checked = optIn, onCheckedChange = {
                optIn = it
                DataTalksPush.setMarketingOptIn(it)
            })
            Text("Marketing pushes")
        }

        OutlinedButton(border = OrangeBorder, onClick = { DataTalksPush.deleteLocalData() }) {
            Text("Delete local data")
        }
        Hint("Deletes this install on the service too. Register starts a new one.")
    }

    @Composable
    private fun EventsSection() {
        if (SampleEvents.lines.isEmpty()) Hint("Nothing yet. Taps, pushes and identify answers show here.")
        SampleEvents.lines.forEach { Text(it, fontSize = 13.sp) }
    }

    @Composable
    private fun Field(label: String, value: String, onChange: (String) -> Unit) {
        OutlinedTextField(value, onChange, Modifier.fillMaxWidth(), label = { Text(label) }, singleLine = true)
    }

    @Composable
    private fun Hint(text: String) {
        Text(text, color = Muted, fontSize = 13.sp)
    }

    private fun keyDescription(key: String): String {
        val match = Regex("^dtpk_(stg|prd)_(live|test)_").find(key) ?: return "A key from the portal's push app, dtpk_prd_test_…"
        val environment = if (match.groupValues[1] == "stg") "Staging" else "Production"
        val mode = match.groupValues[2]
        return if (mode == "live") "$environment, live key. A sandbox should use a test key." else "$environment, test key"
    }
}
