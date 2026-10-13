import SwiftUI
import AppKit

/// Server, login and test controls for the SSH tunnel. Shown as a Settings tab and as a sheet in Simple mode.
struct VPNSettingsView: View {
    @Environment(SSHTunnelManager.self) private var tunnel
    @State private var keyDraft = ""
    @State private var passphraseDraft = ""
    @State private var passwordDraft = ""
    @State private var keyError: String?
    @State private var showKeyEditor = false
    @State private var localKeys: [String] = []
    @State private var localPassphraseDraft = ""
    @State private var isGenerating = false
    @State private var copied: String?

    var body: some View {
        let s = tunnel.settings
        @Bindable var v = tunnel.settings
        Form {
            Section {
                TextField("Server address", text: $v.host, prompt: Text("203.0.113.10 or vpn.example.com"))
                    .autocorrectionDisabled()
                TextField("SSH port", value: $v.sshPort, format: .number.grouping(.never))
                TextField("Username", text: $v.username, prompt: Text("root"))
                    .autocorrectionDisabled()
            } header: {
                Text("Server")
            } footer: {
                Text("The server you log in to with ssh. Downloads and the browser in this app go through it; the rest of your Mac keeps its normal network.")
            }

            Section("Login") {
                Picker("Method", selection: $v.authMethod) {
                    ForEach(VPNAuthMethod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                switch s.authMethod {
                case .localKey: localKeyFields(s)
                case .key: keyFields(s)
                case .password: passwordFields(s)
                }
            }

            if let pub = s.publicKey { publicKeySection(pub) }

            Section {
                TextField("Local proxy port", value: $v.localPort, format: .number.grouping(.never))
            } header: {
                Text("Advanced")
            } footer: {
                Text("Port on this Mac used by the tunnel. Leave 1080 unless it is taken.")
            }

            Section("Connection") {
                Toggle(isOn: Binding(get: { tunnel.wantsVPN }, set: { tunnel.setOn($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use SSH tunnel")
                        Text(connectionText).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(tunnel.status.isConnecting || s.missingField != nil)
                HStack {
                    Button("Test connection") { Task { await tunnel.test() } }
                        .disabled(tunnel.isTesting || tunnel.status.isConnecting)
                    Button("Forget server") { Task { await tunnel.forgetServer() } }
                        .help("Remove the saved fingerprint. You will be asked to trust the server again.")
                    if tunnel.isTesting { ProgressView().controlSize(.small) }
                }
                if let result = tunnel.testResult {
                    Text(result).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let missing = s.missingField {
                    Text(missing).font(.callout).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { localKeys = VPNSettings.discoverLocalKeys() }
    }

    private var connectionText: String {
        switch tunnel.status {
        case .connected(let ip, _): return "On. Downloads and the browser exit from \(ip ?? "your server")."
        case .connecting: return "Connecting…"
        case .failed(let m): return m
        case .disconnected: return "Off. Downloads and the browser use your normal network."
        }
    }

    // MARK: - Key on this Mac

    @ViewBuilder
    private func localKeyFields(_ s: VPNSettings) -> some View {
        @Bindable var v = s
        let options = localKeys.contains(s.localKeyPath) || s.localKeyPath.isEmpty ? localKeys : [s.localKeyPath] + localKeys
        HStack {
            if options.isEmpty {
                Text("No keys found in ~/.ssh").foregroundStyle(.secondary)
            } else {
                Picker("Key file", selection: $v.localKeyPath) {
                    ForEach(options, id: \.self) { Text(displayPath($0)).tag($0) }
                }
            }
            Spacer()
            Button("Choose file…") { chooseKeyFile(s) }
        }
        SecureField("Key passphrase (optional)", text: $localPassphraseDraft,
                    prompt: Text(s.hasLocalKeyPassphrase ? "Saved. Type to replace" : "Only if the key has one"))
        HStack {
            Button("Save") { s.saveLocalKeyPassphrase(localPassphraseDraft); localPassphraseDraft = "" }
                .disabled(localPassphraseDraft.isEmpty)
            if s.hasLocalKeyPassphrase {
                Button("Remove passphrase") { s.saveLocalKeyPassphrase("") }
            }
        }
        Text("The app reads the key from this file each time it connects. A passphrase added with ssh-add --apple-use-keychain is used automatically, so you can leave the field empty.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func chooseKeyFile(_ s: VPNSettings) {
        let panel = NSOpenPanel()
        panel.title = "Choose your private key"
        panel.message = "Pick the key file without .pub, for example id_ed25519."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = VPNSettings.sshDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var path = url.path
        if path.hasSuffix(".pub") { path.removeLast(4) }   // they picked the public half; use its private key
        s.localKeyPath = path
        localKeys = VPNSettings.discoverLocalKeys()
    }

    // MARK: - Public key

    private func publicKeySection(_ pub: String) -> some View {
        Section {
            Text(pub)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
            HStack {
                Button("Copy public key") { copy(pub, label: "key") }
                Button("Copy install command") { copy(installCommand(pub), label: "command") }
                    .help("Run this on the server to allow this key to log in.")
                if let copied { Text("Copied \(copied).").font(.caption).foregroundStyle(.secondary) }
            }
        } header: {
            Text("Public key")
        } footer: {
            Text("Put this on the server, in ~/.ssh/authorized_keys of the user above. The install command does it for you when run on the server. The public key is safe to share.")
        }
    }

    private func installCommand(_ pub: String) -> String {
        let quoted = pub.replacingOccurrences(of: "'", with: "'\\''")
        return "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '\(quoted)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = label
    }

    // MARK: - Key

    @ViewBuilder
    private func keyFields(_ s: VPNSettings) -> some View {
        if s.hasPrivateKey && !showKeyEditor {
            HStack {
                Label("Private key saved in Keychain", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Spacer()
                Button("Replace") { showKeyEditor = true }
                Button("Remove", role: .destructive) { s.removeKey(); keyDraft = "" }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Private key").font(.callout)
                TextEditor(text: $keyDraft)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text("Paste the whole content of id_ed25519 or id_rsa, from -----BEGIN to -----END. Show it with: cat ~/.ssh/id_ed25519. Never share it with anyone.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Generate new key") { generateKey(s) }
                        .disabled(isGenerating)
                        .help("Create a new ed25519 key in this app. Then put its public key on the server.")
                    if isGenerating { ProgressView().controlSize(.small) }
                    if s.hasPrivateKey {
                        Button("Cancel") { showKeyEditor = false; keyDraft = ""; keyError = nil }
                    }
                }
                if let keyError { Text(keyError).font(.caption).foregroundStyle(.red) }
            }
        }
        SecureField("Key passphrase (optional)", text: $passphraseDraft,
                    prompt: Text(s.hasPassphrase ? "Saved. Type to replace" : "Only if the key has one"))
        HStack {
            Button("Save") { saveKey(s) }
                .disabled(keyDraft.isEmpty && passphraseDraft.isEmpty)
            if s.hasPassphrase {
                Button("Remove passphrase") { s.savePassphrase("") }
            }
        }
    }

    private func saveKey(_ s: VPNSettings) {
        keyError = nil
        if !keyDraft.isEmpty {
            do {
                try s.saveKey(keyDraft)
                keyDraft = ""
                showKeyEditor = false
            } catch {
                keyError = error.localizedDescription
                return
            }
        }
        if !passphraseDraft.isEmpty {
            s.savePassphrase(passphraseDraft)
            passphraseDraft = ""
        }
    }

    private func generateKey(_ s: VPNSettings) {
        keyError = nil
        isGenerating = true
        Task {
            defer { isGenerating = false }
            do {
                try await s.generateKey()
                keyDraft = ""
                showKeyEditor = false
            } catch {
                keyError = "Could not create a key. \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Password

    @ViewBuilder
    private func passwordFields(_ s: VPNSettings) -> some View {
        SecureField("Password", text: $passwordDraft,
                    prompt: Text(s.hasPassword ? "Saved. Type to replace" : "Your SSH login password"))
        HStack {
            Button("Save") { s.savePassword(passwordDraft); passwordDraft = "" }
                .disabled(passwordDraft.isEmpty)
            if s.hasPassword {
                Label("Saved in Keychain", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Button("Remove", role: .destructive) { s.removePassword() }
            }
        }
        Text("A key is safer than a password. Servers that only accept keys will refuse this.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// Toolbar control: a coloured dot shows the state, the popover has the on/off switch.
struct VPNToolbarButton: View {
    @Environment(SSHTunnelManager.self) private var tunnel
    @Binding var open: Bool

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text("SSH").foregroundStyle(Theme.text2)
            }
            .padding(.horizontal, 10).frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(statusText)
        .accessibilityLabel("SSH tunnel \(statusText)")
    }

    private var color: Color {
        switch tunnel.status {
        case .connected(_, let verified): return verified ? .green : .orange
        case .connecting: return .yellow
        case .failed: return .red
        case .disconnected: return tunnel.wantsVPN ? .red : .gray
        }
    }

    private var statusText: String {
        switch tunnel.status {
        case .disconnected: return "SSH tunnel off"
        case .connecting: return "SSH tunnel connecting…"
        case .connected: return "SSH tunnel connected"
        case .failed(let m): return "SSH tunnel error: \(m)"
        }
    }
}

struct VPNPopover: View {
    @Environment(SSHTunnelManager.self) private var tunnel
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { tunnel.wantsVPN }, set: { tunnel.setOn($0) })) {
                Text("Connect through SSH tunnel").font(.headline)
            }
            .toggleStyle(.switch)
            .disabled(tunnel.status.isConnecting)

            Group {
                switch tunnel.status {
                case .disconnected:
                    Text("Downloads and the browser use your normal network.")
                case .connecting:
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Connecting…") }
                case .connected(let ip, let verified):
                    if verified {
                        Label("Connected. Exit IP \(ip ?? "unknown")", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Connected, but traffic could not pass through. The server may block TCP forwarding.",
                              systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                case .failed(let message):
                    Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            if tunnel.wantsVPN && !tunnel.status.isConnected {
                Text("Downloads and the browser are paused from using the network until the tunnel is back.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            // Settings is a tab of the main window, not a SwiftUI Settings scene, so SettingsLink did nothing.
            Button("SSH tunnel settings…") {
                dismiss()
                NSApp.activate(ignoringOtherApps: true)
                SettingsTab.open(.tunnel)
            }
        }
        .padding(14)
        .frame(width: 290)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }
}
