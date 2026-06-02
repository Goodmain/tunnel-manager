import SwiftUI

/// Root popover, 360pt wide, with a Connections | + New | Settings tab bar
/// (menu-bar-presentation capability).
struct PopoverView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case connections = "Connections"
        case new = "+ New"
        case settings = "Settings"
        var id: String { rawValue }
    }

    @State private var selection: Tab = .connections

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 360)
        .frame(minHeight: 360, maxHeight: 520)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: selection == tab ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundColor(selection == tab ? .accentColor : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .connections:
            ConnectionsListView()
        case .new:
            AddConnectionView { selection = .connections }
        case .settings:
            SettingsView()
        }
    }
}

/// Connections tab — list of rows, or an empty-state nudge (menu-bar spec).
struct ConnectionsListView: View {
    @EnvironmentObject private var store: ConnectionStore

    var body: some View {
        if store.connections.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary)
                Text("No connections yet")
                    .font(.headline)
                Text("Use the “+ New” tab to add one.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.connections) { connection in
                        ConnectionRowView(connection: connection)
                        Divider()
                    }
                }
            }
        }
    }
}
