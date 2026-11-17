import DataTalksPush
import SwiftUI

/// The sandbox demo: start the SDK with a key, request the permission, identify (with a token from the portal's "Test a token"),
/// log out, set consent, delete, and show what the SDK reports.
struct ContentView: View {
    @ObservedObject private var events = SampleEvents.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var appKey = SampleSettings().appKey ?? ""
    @State private var baseUrl = SampleSettings().baseUrl ?? ""
    @State private var externalId = ""
    @State private var email = ""
    @State private var identityToken = ""
    @State private var marketingOptIn = true
    @State private var permission = "unknown"

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 12) {
                    card("App") {
                        field("App key", text: $appKey)
                        hint(Self.describe(key: appKey))
                        field("Host, only for a local ingress", text: $baseUrl)
                        HStack {
                            Button("Register", action: register).buttonStyle(FilledButton())
                            Button("Ask for permission", action: requestPermission).buttonStyle(OutlinedButton())
                        }
                        hint("Permission: \(permission)")
                    }

                    card("User") {
                        field("External id", text: $externalId)
                        field("Email", text: $email)
                        field("Identity token", text: $identityToken)
                        hint("Paste a token from the portal's Test a token, or leave it empty for an unverified identify.")
                        HStack {
                            Button("Identify", action: identify).buttonStyle(FilledButton())
                            Button("Log out") { DataTalksPush.logout() }.buttonStyle(OutlinedButton())
                        }
                    }

                    card("Device") {
                        Toggle("Marketing pushes", isOn: Binding(get: { marketingOptIn }, set: setMarketingOptIn))
                            .tint(.brandOrange)
                        Button("Delete local data") { DataTalksPush.deleteLocalData() }.buttonStyle(OutlinedButton())
                        hint("Deletes this install on the service too. Register starts a new one.")
                    }

                    card("Events") {
                        if events.lines.isEmpty {
                            hint("Nothing yet. Taps, pushes and identify answers show here.")
                        }
                        ForEach(Array(events.lines.enumerated()), id: \.offset) { line in
                            Text(line.element).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(Color.page.ignoresSafeArea())
        .onAppear(perform: refreshPermission)
        // The permission can change in Settings while the app is in the background.
        .onChange(of: scenePhase) { phase in
            if phase == .active { refreshPermission() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image("DataTalksMark").resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Data Talks").font(.title3.bold()).foregroundColor(.white)
                Text("Push SDK demo · Native iOS").font(.footnote).foregroundColor(.white.opacity(0.7))
            }
            Spacer()
            Text("SANDBOX")
                .font(.caption2.bold())
                .kerning(1.5)
                .foregroundColor(.brandIndigo)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.brandIndigo.ignoresSafeArea(edges: .top))
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.bold()).kerning(1).foregroundColor(.brandIndigo)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.roundedBorder)
            .autocapitalization(.none)
            .disableAutocorrection(true)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundColor(.muted)
    }

    private func register() {
        let key = appKey.trimmingCharacters(in: .whitespaces)
        let settings = SampleSettings()
        settings.appKey = key
        settings.baseUrl = baseUrl.isEmpty ? nil : baseUrl
        DataTalksPush.initialize(appKey: key, options: DataTalksPushOptions(baseUrl: settings.baseUrl))
    }

    private func requestPermission() {
        DataTalksPush.requestPermission { result in
            permission = result.rawValue
            events.add("Permission: \(result.rawValue)")
        }
    }

    private func refreshPermission() {
        DataTalksPush.permissionStatus { permission = $0.rawValue }
    }

    private func identify() {
        DataTalksPush.identify(
            externalId: externalId.isEmpty ? nil : externalId,
            email: email.isEmpty ? nil : email,
            identityToken: identityToken.isEmpty ? nil : identityToken
        )
    }

    private func setMarketingOptIn(_ optIn: Bool) {
        marketingOptIn = optIn
        DataTalksPush.setMarketingOptIn(optIn)
    }

    static func describe(key: String) -> String {
        let parts = key.split(separator: "_")
        guard key.hasPrefix("dtpk_"), parts.count >= 4, ["stg", "prd"].contains(parts[1]), ["live", "test"].contains(parts[2]) else {
            return "A key from the portal's push app, dtpk_prd_test_…"
        }

        let environment = parts[1] == "stg" ? "Staging" : "Production"
        return parts[2] == "live" ? "\(environment), live key. A sandbox should use a test key." : "\(environment), test key"
    }
}

private struct FilledButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.brandOrange.opacity(configuration.isPressed ? 0.8 : 1)))
    }
}

private struct OutlinedButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundColor(.brandOrange)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().stroke(Color.brandOrange, lineWidth: 1.5))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

private extension Color {
    static let brandOrange = Color(red: 0xF3 / 255, green: 0x56 / 255, blue: 0x25 / 255)
    static let brandIndigo = Color(red: 0x1F / 255, green: 0x14 / 255, blue: 0x51 / 255)
    static let page = Color(red: 0xEE / 255, green: 0xF1 / 255, blue: 0xF8 / 255)
    static let muted = Color(red: 0x5E / 255, green: 0x62 / 255, blue: 0x78 / 255)
}
