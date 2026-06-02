import SwiftUI

/// "+ New" tab — a form covering every connection field with validation
/// (menu-bar-presentation + connection-management specs).
struct AddConnectionView: View {
    /// When set, the form edits this connection instead of creating a new one (D15).
    var editing: Connection?
    /// Called after a successful save (e.g. to switch back to the Connections tab).
    var onSaved: () -> Void = {}

    @EnvironmentObject private var store: ConnectionStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var tunnels: TunnelManager
    @EnvironmentObject private var profiles: AWSProfileStore

    @State private var name = ""
    @State private var awsProfile = ""
    @State private var ecsCluster = ""
    @State private var dbHost = ""
    @State private var remotePort = "5432"
    @State private var localPort = "5432"
    @State private var environment: DeploymentEnvironment = .dev

    @State private var errorMessage: String?
    @State private var warningMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                field("Name", text: $name, placeholder: "Prod DB")
                profileField
                field("ECS Cluster", text: $ecsCluster, placeholder: "my-cluster")
                field("DB Host", text: $dbHost, placeholder: "db.internal.example.com")

                HStack(spacing: 8) {
                    field("Remote Port", text: $remotePort)
                    field("Local Port", text: $localPort)
                }

                Picker("Environment", selection: $environment) {
                    ForEach(DeploymentEnvironment.allCases) { env in
                        Text(env.label).tag(env)
                    }
                }
                .pickerStyle(.segmented)

                if let warningMessage {
                    Label(warningMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "xmark.octagon")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Button(action: save) {
                    Text(editing == nil ? "Save" : "Update")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .padding(.top, 4)
            }
            .padding(12)
        }
        .onAppear {
            if let editing {
                name = editing.name
                awsProfile = editing.awsProfile
                ecsCluster = editing.ecsCluster
                dbHost = editing.dbHost
                remotePort = String(editing.remotePort)
                localPort = String(editing.localPort)
                environment = editing.environment
            } else if awsProfile.isEmpty {
                // Prefer the configured default; otherwise the first discovered profile
                // so the Picker has a valid selection (D5).
                let list = profiles.profiles
                if !settings.defaultAWSProfile.isEmpty {
                    awsProfile = settings.defaultAWSProfile
                } else if let first = list.first {
                    awsProfile = first
                }
            }
        }
    }

    /// Options shown in the profile picker: discovered profiles, plus the current
    /// value if it isn't in the list (e.g. editing a connection whose profile was
    /// removed from config) so it is never silently dropped (D4).
    private var profileOptions: [String] {
        var options = profiles.profiles
        if !awsProfile.isEmpty && !options.contains(awsProfile) {
            options.insert(awsProfile, at: 0)
        }
        return options
    }

    @ViewBuilder
    private var profileField: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("AWS Profile").font(.caption).foregroundColor(.secondary)
            if profiles.profiles.isEmpty {
                // Fallback to free text when no profiles were discovered (D4).
                TextField("my-profile", text: $awsProfile)
                    .textFieldStyle(.roundedBorder)
            } else {
                Picker("", selection: $awsProfile) {
                    ForEach(profileOptions, id: \.self) { profile in
                        Text(profile).tag(profile)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundColor(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func save() {
        errorMessage = nil
        warningMessage = nil
        guard let rPort = Int(remotePort), let lPort = Int(localPort) else {
            errorMessage = "Ports must be numbers."
            return
        }
        let connection = Connection(
            id: editing?.id ?? UUID(),
            name: name, awsProfile: awsProfile, ecsCluster: ecsCluster,
            dbHost: dbHost, remotePort: rPort, localPort: lPort, environment: environment
        )
        do {
            warningMessage = try store.validate(connection, isNew: editing == nil)
            if let editing {
                store.update(connection)
                tunnels.handleEdit(old: editing, new: connection)  // restart live tunnel if needed (D15)
            } else {
                store.add(connection)
            }
            onSaved()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
