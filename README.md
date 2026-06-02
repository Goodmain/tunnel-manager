# Tunnel Manager

A macOS menu bar app for managing AWS SSM port-forwarding tunnels into ECS-hosted
databases — one click per connection, self-healing, always visible in the menu bar.

Each connection wraps:

```
aws-vault exec <profile> -- aws ssm start-session \
  --target ecs:<cluster>_<taskId>_<runtimeId> \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["<dbHost>"],"portNumber":["<remotePort>"],"localPortNumber":["<localPort>"]}'
```

The ECS target is resolved automatically (`list-tasks` → `describe-tasks`), tunnels
run as their own process group, and dropped tunnels auto-reconnect.

## Features

- Menu bar only — no Dock icon (`LSUIElement`); icon tints green + shows count when tunnels are active.
- Define connections (name, AWS profile, ECS cluster, DB host, remote/local ports, environment).
- Per-connection state: disconnected / connecting / connected / reconnecting / failed.
- Auto-reconnect on unexpected drops; never fights a user-initiated stop.
- Sleep/wake aware — staggered reconnects, single MFA prompt instead of a thundering herd.
- Persists connections + settings to `UserDefaults` (no secrets stored).

## Install

Via Homebrew (recommended):

```bash
brew tap Goodmain/tunnel-manager
brew install --cask tunnel-manager
```

This also installs the runtime tools the app needs (`aws-vault`, `awscli`, `session-manager-plugin`).

Upgrade / uninstall:

```bash
brew upgrade --cask tunnel-manager
brew uninstall --cask tunnel-manager
```

> The app is ad-hoc signed, not notarized (no paid Apple account). The cask clears the
> download quarantine on install so it launches normally.

To build from source instead, see [Build & run](#build--run).

## Requirements

- macOS 13+
- [`aws-vault`](https://github.com/99designs/aws-vault)
- [`aws` CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [`session-manager-plugin`](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)

Install via Homebrew:

```bash
brew install aws-vault awscli
brew install --cask session-manager-plugin
```

The app resolves these from your login-shell `PATH` and adds `/opt/homebrew/bin` and
`/usr/local/bin` as fallbacks. If they live elsewhere, set a binary directory in **Settings**.

Your ECS tasks/containers must have **ECS Exec enabled** (`enableExecuteCommand`) and your
IAM principal needs `ssm:StartSession` on the target.

## Build & run

Open in Xcode (requires full Xcode, not just Command Line Tools):

```bash
open TunnelManager.xcodeproj
```

Set your signing team, then **⌘R**. The app launches into the menu bar (no window — by design).

> App Sandbox is **off** (see design decision D13): the app must launch external
> CLIs, which a sandbox forbids. This also means it is not distributable via the
> Mac App Store. Launch-at-login (`SMAppService`) requires the app to be code-signed
> and run from a stable path such as `/Applications`.

### Headless build (no full Xcode)

```bash
SDK=$(xcrun --show-sdk-path)
swiftc -sdk "$SDK" -target arm64-apple-macos13.0 \
  -framework AppKit -framework SwiftUI -parse-as-library \
  -o /tmp/TunnelManager TunnelManager/**/*.swift
```

Useful for a fast type-check / link verification.

## Usage

1. Click the menu bar icon → **+ New** → fill in the connection → **Save**.
2. **Connections** tab → flip the toggle to start the tunnel.
3. Connect your DB client to `127.0.0.1:<localPort>`.

Right-click a row to **Edit** or **Delete**. Editing tunnel-affecting fields of a live
connection restarts it automatically.

## Project layout

```
TunnelManager/
├── TunnelManagerApp.swift     @main entry (menu-bar only)
├── AppDelegate.swift          NSStatusItem + NSPopover, icon, teardown
├── TunnelManager.swift        @MainActor engine: state machine, reconnect, sleep/wake, auth gate
├── ConnectionStore.swift      JSON ↔ UserDefaults, validation
├── SettingsStore.swift        prefs + SMAppService launch-at-login
├── Models/                    Connection.swift, TunnelState.swift
├── Support/                   PathResolver, SpawnedProcess (posix_spawn), PortProbe,
│                              CommandRunner, ECSResolver
├── Views/                     PopoverView, ConnectionRowView, AddConnectionView, SettingsView
├── Info.plist                 LSUIElement = true
└── TunnelManager.entitlements App Sandbox OFF
```

`gen_pbxproj.py` regenerates `TunnelManager.xcodeproj/project.pbxproj` deterministically.

## Known limitations

- **Task selection (D6):** with many running tasks, the resolver picks the *first* RUNNING
  task. If its container lacks ECS Exec, the tunnel fails — pick a cluster/profile whose
  first task is exec-enabled, or extend the resolver to filter on `enableExecuteCommand`.
- Manual verification of teardown / reconnect / persistence (tasks 9.3–9.5) is pending.

## License

MIT — see [LICENSE](LICENSE).
