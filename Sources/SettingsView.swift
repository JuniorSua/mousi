import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @State private var apiKey: String = Settings.apiKey ?? ""
    @State private var backend: Backend = Settings.backend
    @State private var cliPath: String? = ClaudeCLI.locate()
    @State private var model: String = Settings.model
    @State private var enabled: Bool = Settings.enabled
    @State private var clipboardFallback: Bool = Settings.clipboardFallback
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var testState: TestState = .idle
    @State private var axTrusted: Bool = Accessibility.isTrusted
    let onChange: () -> Void

    enum TestState: Equatable { case idle, testing, ok, failed(String) }

    var body: some View {
        Form {
            Section {
                Toggle("Show pill when I highlight text", isOn: $enabled)
                    .onChange(of: enabled) { _, v in Settings.enabled = v; onChange() }
                Toggle("Launch Mousi at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in
                        do {
                            if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                HStack {
                    Label(axTrusted ? "Accessibility access granted" : "Accessibility access needed",
                          systemImage: axTrusted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(axTrusted ? .green : .orange)
                    Spacer()
                    if !axTrusted {
                        Button("Open System Settings") { Accessibility.openSystemSettings() }
                    }
                }
                .font(.callout)
            } header: {
                Text("General")
            } footer: {
                Text("Mousi needs Accessibility access to see what you highlight and to send Copy/Paste to other apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Use", selection: $backend) {
                    ForEach(Backend.allCases) { b in Text(b.label).tag(b) }
                }
                .onChange(of: backend) { _, v in Settings.backend = v; testState = .idle }

                if backend == .subscription {
                    HStack {
                        if let path = cliPath {
                            Label("Claude Code found", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .help(path)
                        } else {
                            Label("Claude Code not found", systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        testButton
                    }
                    .font(.callout)
                } else {
                    HStack {
                        SecureField("sk-ant-…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: apiKey) { _, v in
                                Settings.apiKey = v.trimmingCharacters(in: .whitespacesAndNewlines)
                                testState = .idle
                            }
                        testButton
                    }
                }
                if case .failed(let msg) = testState {
                    Text(msg).font(.caption).foregroundStyle(.red)
                }
                Picker("Model", selection: $model) {
                    ForEach(ModelOption.all) { m in
                        VStack(alignment: .leading) {
                            Text(m.name)
                            Text(m.note).font(.caption).foregroundStyle(.secondary)
                        }.tag(m.id)
                    }
                }
                .onChange(of: model) { _, v in Settings.model = v }
                Toggle("Clipboard fallback for apps that hide their selection", isOn: $clipboardFallback)
                    .onChange(of: clipboardFallback) { _, v in Settings.clipboardFallback = v }
            } header: {
                Text("Rewrite (Claude)")
            } footer: {
                Text(backend == .subscription
                     ? "Rewrites run through the Claude Code CLI signed in with your Claude subscription (no API key). Haiku is the fastest, lightest option and counts least against your plan."
                     : "Get a key at console.anthropic.com. Haiku 4.5 is fast and inexpensive — a typical rewrite costs a fraction of a cent. The key is stored in this app's preferences on your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axTrusted = Accessibility.isTrusted
        }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            axTrusted = Accessibility.isTrusted
        }
    }

    private var testButton: some View {
        Button(action: test) {
            switch testState {
            case .idle: Text("Test")
            case .testing: ProgressView().controlSize(.small)
            case .ok: Label("Works", systemImage: "checkmark").foregroundStyle(.green)
            case .failed: Label("Failed", systemImage: "xmark").foregroundStyle(.red)
            }
        }
        .disabled((backend == .apiKey && apiKey.isEmpty) || testState == .testing)
        .frame(minWidth: 70)
    }

    private func test() {
        testState = .testing
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = backend
        Task { @MainActor in
            let r: Result<Void, ClaudeError> = mode == .subscription
                ? await ClaudeCLI.test()
                : await ClaudeClient.testKey(key)
            switch r {
            case .success: testState = .ok
            case .failure(let e): testState = .failed(e.localizedDescription)
            }
        }
    }
}
