import SwiftUI

struct NetworkTabView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        @Bindable var options = appState.downloadOptions
        
        Form {
            Section("Network") {
                TextField("Proxy URL", text: Binding(
                    get: { options.proxy ?? "" },
                    set: { options.proxy = $0.isEmpty ? nil : $0 }
                ))
                Stepper("Socket Timeout: \(options.socketTimeout ?? 0)", value: Binding(
                    get: { options.socketTimeout ?? 0 },
                    set: { options.socketTimeout = $0 }
                ), in: 0...600)
                TextField("Source Address", text: Binding(
                    get: { options.sourceAddress ?? "" },
                    set: { options.sourceAddress = $0.isEmpty ? nil : $0 }
                ))
                Toggle("Force IPv4", isOn: $options.forceIPv4)
                Toggle("Force IPv6", isOn: $options.forceIPv6)
                TextField("Impersonate Client", text: Binding(
                    get: { options.impersonate ?? "" },
                    set: { options.impersonate = $0.isEmpty ? nil : $0 }
                ))
            }
            
            Section("Geo-restriction") {
                TextField("Geo Verification Proxy", text: Binding(
                    get: { options.geoVerificationProxy ?? "" },
                    set: { options.geoVerificationProxy = $0.isEmpty ? nil : $0 }
                ))
                TextField("X-Forwarded-For", text: Binding(
                    get: { options.xff ?? "" },
                    set: { options.xff = $0.isEmpty ? nil : $0 }
                ))
            }
            
            Section("Authentication") {
                TextField("Username", text: Binding(
                    get: { options.username ?? "" },
                    set: { options.username = $0.isEmpty ? nil : $0 }
                ))
                SecureField("Password", text: Binding(
                    get: { options.password ?? "" },
                    set: { options.password = $0.isEmpty ? nil : $0 }
                ))
                TextField("Two-Factor Code", text: Binding(
                    get: { options.twofactor ?? "" },
                    set: { options.twofactor = $0.isEmpty ? nil : $0 }
                ))
                SecureField("Video Password", text: Binding(
                    get: { options.videoPassword ?? "" },
                    set: { options.videoPassword = $0.isEmpty ? nil : $0 }
                ))
                Toggle("Use Netrc", isOn: $options.netrc)
                TextField("Netrc Location", text: Binding(
                    get: { options.netrcLocation ?? "" },
                    set: { options.netrcLocation = $0.isEmpty ? nil : $0 }
                ))
            }
            
            Section("Cookies") {
                TextField("Cookies File", text: Binding(
                    get: { options.cookiesFile ?? "" },
                    set: { options.cookiesFile = $0.isEmpty ? nil : $0 }
                ))
                TextField("Cookies from Browser", text: Binding(
                    get: { options.cookiesFromBrowser ?? "" },
                    set: { options.cookiesFromBrowser = $0.isEmpty ? nil : $0 }
                ))
                .help("chrome, firefox, safari, edge, brave, opera, vivaldi")
            }
        }
        .formStyle(.grouped)
    }
}
