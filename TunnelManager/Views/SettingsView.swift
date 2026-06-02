import SwiftUI

/// Settings tab (app-settings capability): default profile, reconnect delay,
/// launch at login, auto-reconnect, binary directory override.
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var tunnels: TunnelManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let dependencyError = tunnels.dependencyError {
                    Label(dependencyError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                group("Default AWS Profile") {
                    TextField("my-profile", text: $settings.defaultAWSProfile)
                        .textFieldStyle(.roundedBorder)
                }

                group("Reconnect Delay") {
                    HStack {
                        Slider(value: $settings.reconnectDelay, in: 1...60, step: 1)
                        Text("\(Int(settings.reconnectDelay))s")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 36, alignment: .trailing)
                    }
                }

                Toggle("Auto-reconnect dropped tunnels", isOn: $settings.autoReconnect)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)

                group("Binary Directory Override") {
                    TextField("/opt/homebrew/bin", text: $settings.binaryDirectoryOverride)
                        .textFieldStyle(.roundedBorder)
                    Text("Optional. Where aws-vault / aws / session-manager-plugin live, if not on PATH.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Divider()
                Button("Quit Tunnel Manager") {
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
            }
            .padding(12)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            content()
        }
    }
}
