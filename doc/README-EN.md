# 1PanelClient

iOS client for [1Panel](https://1panel.cn) — the open-source Linux server management panel.

Built natively with Swift + SwiftUI, it manages your servers remotely via the 1Panel v2 OpenAPI.

> 中文文档：[README-CN.md](README-CN.md)
>
> Full feature list & details: [FEATURES.md](FEATURES.md) (Chinese)

## Features

### Overview (Home)
- Resource cards (CPU, memory, disk, network, load) with real-time monitoring charts
- System info (hostname, OS version, kernel, uptime)
- Panel version update detection, certificate expiry countdown
- Multi-node overview card, app / container status cards

### Manage
- **Apps** — Installed app management, app store install/uninstall, upgrades (Compose diff view), app logs
- **Websites** — Website list & config, reverse proxy, SSL certificate management (apply / manual / self-signed / DNS / HTTP), website logs, website monitoring
- **Databases** — MySQL / PostgreSQL / Redis instance management, database terminal, connection info
- **Containers** — Docker container list / create / edit / details / terminal, image management (pull / prune / registries), live container monitoring
- **Cronjobs** — CRUD, run now, execution records, log viewing, script library
- **Terminal** — WebSocket remote terminal (host / container / database / SSH hosts)
- **Files** — Server file management
- **Monitor** — Load / CPU / memory / disk I/O / network charts
- **Processes** — System process monitoring
- **Firewall / Fail2ban / WAF** — Port & IP rules, SSH brute-force protection, web application firewall (rules / blocklists-allowlists / monitoring)
- **Alerts** — Alert rules, alert logs, delivery method configuration
- **Backup Accounts** — MINIO / WebDAV / SFTP backup storage and backup lists
- **Task Center** — Async tasks (app sync, image pull, etc.) with logs
- **Logs** — Panel / operation / SSH login / website logs
- **Panel & Server** — Restart panel and server
- **Multi-node** — Node overview / details / add / switch (1Panel Pro), the whole app follows the current node

### Settings
- Multi-server management (credentials stored in Keychain), connection testing
- "HTTPS only" toggle (off by default; when enabled, all plaintext `http://` panel addresses are rejected, and saving an HTTP address shows a plaintext-risk warning)
- App Lock (FaceID / TouchID biometrics with 4-digit passcode fallback)
- Appearance (system / light / dark) and UI language (English / Chinese, applied instantly)

### Home Screen Widgets
- Server status widget and container quick-actions widget (interactive App Intents buttons)

See [FEATURES.md](FEATURES.md) for detailed per-module descriptions (Chinese).

## Screenshots

<!-- TODO: add screenshots -->

## Requirements

- iOS 26.0+ (matches the project deployment target)
- Xcode 26+
- 1Panel v2 (OpenAPI must be enabled and an API Key created on the panel; v1 is not supported)

## Installation

### Option 1: LiveContainer (no jailbreak, recommended)

1. Download the latest `1PanelClient.ipa` from [Releases](https://github.com/xy2026yi/1PanelClient/releases)
2. Transfer the IPA to your iPhone
3. Import and run it with [LiveContainer](https://github.com/khanhduytran0/LiveContainer)

### Option 2: Sideload

If you have an Apple Developer account or a sideload tool (AltStore / Sideloadly / TrollStore), sign and install the IPA directly.

### Option 3: Build from source

```bash
git clone https://github.com/xy2026yi/1PanelClient.git
cd 1PanelClient
```

Open `1PanelClient.xcodeproj` in Xcode, change the Bundle ID and Team, then Build & Run on a real device.

## Building an IPA from Source

The repo ships an unsigned-IPA packaging script (no certificate needed):

```bash
cd 1PanelClient
./build-ipa.sh                    # outputs to ~/Desktop/1PanelClient.ipa
./build-ipa.sh ~/path/to/output.ipa  # custom output path
```

The generated IPA is unsigned, suitable for LiveContainer or sideload tools.

## Running Tests

```bash
cd 1PanelClient
xcodebuild test -project 1PanelClient.xcodeproj -scheme 1PanelClient \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Or simply press Cmd+U in Xcode. The Swift Testing suite covers: the token signing algorithm (fixed MD5 vectors), API response envelope parsing, Keychain CRUD, connection security policy (plaintext http detection / HTTPS-only enforcement), app upgrade Compose diffs, monitor chart windows, node & multi-node models, website & WAF monitoring models, App Intents, and localization.

## Project Structure

```
1PanelClient/
├── 1PanelClient/                # Main app target
│   ├── _PanelClientApp.swift    # App entry
│   ├── ContentView.swift
│   ├── Assets.xcassets
│   └── Features/                # Feature modules (Main/Overview/Manage/Apps/
│   │                            #   Websites/Certificates/Databases/Containers/
│   │                            #   Cronjobs/Terminal/Firewall/Process/Toolbox/
│   │                            #   Backups/Logs/Server/Settings …)
├── PanelShared/                 # Code shared between app and widgets
│   ├── Core/                    # APIClient / APIEndpoints / KeychainStore /
│   │                            #   ServerManager / SecurityGate
│   ├── Models/                  # Data models (API responses, entities)
│   ├── Intents/                 # App Intents (Shortcuts / widget interaction)
│   └── Shared/                  # Common components, design tokens, i18n
├── PanelWidgets/                # Widget extension (server status / container quick ops)
├── 1PanelClientTests/           # Unit tests (Swift Testing)
├── scripts/                     # i18n helper scripts (migration / sync)
└── build-ipa.sh                 # Unsigned IPA packaging script
```

## Tech Stack

| Item | Details |
|------|---------|
| Language | Swift 5 |
| UI framework | SwiftUI (NavigationStack push navigation) |
| Minimum OS | iOS 26.0 |
| Networking | URLSession + Combine |
| Terminal | Native URLSessionWebSocketTask |
| Secure storage | Keychain Services (shared with widgets via App Group) |
| Crypto | CryptoKit (MD5 token generation) |
| Widgets | WidgetKit + App Intents |
| Testing | Swift Testing |

## 1Panel API Authentication

The app uses the token authentication scheme of the 1Panel v2 OpenAPI:

```
Timestamp = Unix timestamp (seconds)
Token     = MD5("1panel" + APIKey + Timestamp)

Headers:
  1Panel-Token:     <Token>
  1Panel-Timestamp: <Timestamp>
```

Create the API Key on the 1Panel panel under "Panel Settings → API"; it is stored in the iPhone's Keychain.

## License

MIT
