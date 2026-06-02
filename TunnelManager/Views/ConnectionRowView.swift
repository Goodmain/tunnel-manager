import SwiftUI

/// One connection row: status dot, name, cluster:remote→local summary, env badge,
/// local port chip, toggle (menu-bar-presentation spec).
struct ConnectionRowView: View {
    let connection: Connection

    @EnvironmentObject private var tunnels: TunnelManager
    @EnvironmentObject private var store: ConnectionStore

    @State private var isEditing = false

    private var state: TunnelState { tunnels.state(for: connection.id) }

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(state: state)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(connection.name.isEmpty ? "Untitled" : connection.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    EnvironmentBadge(environment: connection.environment)
                }
                Text(connection.summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if let error = state.failureMessage {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 4)

            PortChip(port: connection.localPort)

            Toggle("", isOn: Binding(
                get: { state.isActive || state.isBusy },
                set: { _ in tunnels.toggle(connection) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contextMenu {
            Button("Edit…") { isEditing = true }
            Button("Delete", role: .destructive) {
                tunnels.stop(id: connection.id, intentional: true)
                store.delete(id: connection.id)
            }
        }
        .sheet(isPresented: $isEditing) {
            VStack(spacing: 0) {
                HStack {
                    Text("Edit Connection").font(.headline)
                    Spacer()
                    Button("Done") { isEditing = false }
                }
                .padding(12)
                Divider()
                AddConnectionView(editing: connection) { isEditing = false }
            }
            .frame(width: 360, height: 460)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(connection.name), \(connection.environment.label), \(state.accessibilityLabel)")
    }
}

/// Status dot: gray (idle/failed), amber pulsing (busy), green (connected).
/// Carries a non-color cue via accessibility label (polish bundle).
private struct StatusDot: View {
    let state: TunnelState
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(state.dotColor)
            .frame(width: 10, height: 10)
            .opacity(state.isBusy && pulse ? 0.3 : 1.0)
            .animation(state.isBusy ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = state.isBusy }
            .onChange(of: state.isBusy) { busy in pulse = busy }
            .accessibilityHidden(true)
    }
}

private struct EnvironmentBadge: View {
    let environment: DeploymentEnvironment

    var body: some View {
        Text(environment.label.uppercased())
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(environment.color.opacity(0.18))
            .foregroundColor(environment.color)
            .clipShape(Capsule())
    }
}

private struct PortChip: View {
    let port: Int

    var body: some View {
        Text(":" + String(port))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
