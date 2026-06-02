import Foundation
import SwiftUI

/// Per-connection runtime state. Five states (design D3): the two extra over
/// the naive three let the UI distinguish "retrying" from "broken" and let the
/// reconnect logic gate on intent.
enum TunnelState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed(String)

    var isActive: Bool {
        switch self {
        case .connected: return true
        default: return false
        }
    }

    /// True while the tunnel is working toward connected (amber pulse in UI).
    var isBusy: Bool {
        switch self {
        case .connecting, .reconnecting: return true
        default: return false
        }
    }

    /// Status dot color: gray (idle/failed), amber (busy), green (connected).
    var dotColor: Color {
        switch self {
        case .disconnected: return .gray
        case .connecting, .reconnecting: return .orange
        case .connected: return .green
        case .failed: return .gray
        }
    }

    /// Non-color accessibility / colorblind cue (design polish bundle).
    var accessibilityLabel: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting, may need MFA"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
