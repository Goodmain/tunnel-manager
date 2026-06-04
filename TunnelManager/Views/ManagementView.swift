import SwiftUI

/// Root of the separate management window: Connections (add/edit/delete) + Settings.
/// Driven by `ManagementState` so the menu bar can open it on a given section.
struct ManagementView: View {
    @EnvironmentObject private var state: ManagementState

    private enum Tab: CaseIterable {
        case connections, settings
        var title: String { self == .connections ? "Connections" : "Settings" }
        var icon: String { self == .connections ? "network" : "gearshape" }
    }
    @State private var tab: Tab = .connections

    var body: some View {
        VStack(spacing: 0) {
            switcher
            Divider()
            content
        }
        .frame(width: 500, height: 470)   // fixed; window is non-resizable
        // Sync from external section changes (menu bar opening a section).
        .onAppear { tab = (state.section == .settings) ? .settings : .connections }
        .onChange(of: state.section) { tab = ($0 == .settings) ? .settings : .connections }
    }

    /// macOS-toolbar-style switcher: centered icon-above-label segments, selected pill.
    private var switcher: some View {
        HStack(spacing: 8) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button { tab = t } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.icon).font(.system(size: 16, weight: .medium))
                        Text(t.title).font(.system(size: 11))
                    }
                    .frame(width: 96)
                    .padding(.vertical, 6)
                    .background(tab == t ? Color.primary.opacity(0.12) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(tab == t ? .primary : .secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .connections: ConnectionsManageView()
        case .settings: SettingsView()
        }
    }
}

/// Scrollable, A-Z connection list with add / edit / delete.
struct ConnectionsManageView: View {
    @EnvironmentObject private var store: ConnectionStore
    @EnvironmentObject private var tunnels: TunnelManager
    @EnvironmentObject private var state: ManagementState

    @State private var editing: Connection?
    @State private var showingAdd = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.sortedConnections) { c in
                        manageRow(c)
                        Divider()
                    }
                }
                .padding(.vertical, 4)
            }
            Divider()
            HStack {
                Spacer()
                Button {
                    showingAdd = true
                } label: { Label("Add Connection", systemImage: "plus") }
            }
            .padding(10)
        }
        // Present add from the menu bar (addToken bump) or the Add button.
        .onChange(of: state.addToken) { _ in showingAdd = true }
        .sheet(isPresented: $showingAdd) {
            sheet(editing: nil)
        }
        .sheet(item: $editing) { conn in
            sheet(editing: conn)
        }
    }

    private func manageRow(_ c: Connection) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name.isEmpty ? "Untitled" : c.name).font(.system(size: 13, weight: .semibold))
                Text("\(c.awsProfile) · \(c.summary)").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Edit") { editing = c }
            Button(role: .destructive) {
                tunnels.stop(id: c.id, intentional: true)
                store.delete(id: c.id)
            } label: { Image(systemName: "trash") }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func sheet(editing conn: Connection?) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(conn == nil ? "Add Connection" : "Edit Connection").font(.headline)
                Spacer()
                Button("Done") { showingAdd = false; editing = nil }
            }
            .padding(12)
            Divider()
            AddConnectionView(editing: conn) { showingAdd = false; editing = nil }
        }
        .frame(width: 360, height: 470)
    }
}
