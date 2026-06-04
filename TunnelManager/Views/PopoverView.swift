import SwiftUI

/// Status-bar popover: header (title + gear menu), A-Z connections list (scroll,
/// dynamic height), footer (active count + add). Settings and connection forms
/// live in the management window (opened via the coordinator).
struct PopoverView: View {
    @EnvironmentObject private var store: ConnectionStore
    @EnvironmentObject private var tunnels: TunnelManager
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 360)
        .frame(minHeight: 160, maxHeight: 520)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundColor(.secondary)
            Text("Tunnel Manager")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            HStack(spacing: 0) {
                iconButton("gearshape", help: "Settings") { coordinator.open(.settings) }
                Divider().frame(height: 18)
                iconButton("power", help: "Quit Tunnel Manager") { coordinator.quit() }
            }
            .background(Color.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Control-Center-style round icon button.
    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var content: some View {
        if store.connections.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 28)).foregroundColor(.secondary)
                Text("No connections yet").font(.headline)
                Text("Use “Add Connection” below to get started.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.sortedConnections) { connection in
                        ConnectionRowView(connection: connection)
                        Divider()
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(tunnels.activeCount) active")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button {
                coordinator.open(.addConnection)
            } label: {
                Label("Add Connection", systemImage: "plus")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
