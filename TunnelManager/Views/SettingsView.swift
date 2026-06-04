import SwiftUI

/// Settings tab (app-settings capability): default profile, reconnect delay,
/// launch at login, auto-reconnect, binary directory override.
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var tunnels: TunnelManager
    @EnvironmentObject private var profiles: AWSProfileStore

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
                    if profiles.profiles.isEmpty {
                        TextField("my-profile", text: $settings.defaultAWSProfile)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("", selection: $settings.defaultAWSProfile) {
                            Text("None").tag("")
                            ForEach(defaultProfileOptions, id: \.self) { profile in
                                Text(profile).tag(profile)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
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

                Stepper(value: $settings.maxReconnectAttempts, in: 1...20) {
                    Text("Max reconnect attempts: \(settings.maxReconnectAttempts)")
                }
                .disabled(!settings.autoReconnect)

                Toggle("Launch at login", isOn: $settings.launchAtLogin)

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Kill process occupying the local port", isOn: $settings.killOrphanOnPort)
                    Text("When on, a process already bound to a connection's local port is terminated before connecting, instead of showing an in-use error.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                group("Binary Directory Override") {
                    TextField("/opt/homebrew/bin", text: $settings.binaryDirectoryOverride)
                        .textFieldStyle(.roundedBorder)
                    Text("Optional. Where aws-vault / aws / session-manager-plugin live, if not on PATH.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Divider()
                Button("Reveal Logs in Finder") {
                    let logger = FileLogger.shared
                    NSWorkspace.shared.activateFileViewerSelecting([logger.logFileURL])
                }
                .controlSize(.small)
            }
            .padding(12)
        }
    }

    /// Discovered profiles, plus the current default if it is no longer in config
    /// so the saved value isn't silently dropped.
    private var defaultProfileOptions: [String] {
        var options = profiles.profiles
        let current = settings.defaultAWSProfile
        if !current.isEmpty && !options.contains(current) {
            options.insert(current, at: 0)
        }
        return options
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            content()
        }
    }
}
