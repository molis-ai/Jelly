# Jelly

Local-first personal productivity app for macOS, with a native iOS app in development.

**Now:** calendar with natural-language quick add (“明天下午 3 点开会”), an undated list, and item reminders delivered through Apple Reminders; structured Block notes that link to each other (type `[[` or `【【`, with backlinks) and calendar–note relations; a raw-first inspiration inbox with system-wide capture (⌃⌥J panel, Services menu, menu bar, Siri / Shortcuts on iOS), AI expansion, a daily review, and one-step “turn into a to-do”; material digests (web, 公众号, PDF, images, 小红书, B 站, podcasts) with “my view” prompts and cross-material synthesis.
**AI:** expansion, decomposition, digests and synthesis all use the model chosen in Settings › 摘要 — a cloud preset with your own key, or the logged-in Codex / Claude CLI on the Mac.
**Also built in:** a built-in MCP server that exposes calendar/schedule operations to AI clients over loopback HTTP (plus a bundled `jelly-mcp` stdio bridge) — see [docs/Jelly-MCP.md](docs/Jelly-MCP.md).

Data stays local. Mac and iPhone can sync through a folder you choose in iCloud Drive (each device writes only its own file) — see [docs/sync.md](docs/sync.md).

| Platform | Entry point | Status |
| --- | --- | --- |
| macOS | [Build from source](#build-from-source) | Existing desktop app |
| iOS / iPadOS | [iOS development guide](iOS/README.md) | Simulator build and basic calendar, notes, and inspiration journeys verified; full parity and device acceptance remain in progress |

## Download

Prebuilt installers are on **[GitHub Releases](https://github.com/molis-ai/Jelly/releases/latest)** — not in this git tree (`dist/` is gitignored).

1. Open the latest release.
2. Download `Jelly.app.zip` (or `Jelly.dmg`).
3. Follow [docs/Jelly-安装说明.md](docs/Jelly-安装说明.md).

Requirements: Apple silicon Mac, macOS 14+. First launch uses Control-click → Open (ad-hoc signed).

## Build from source

### macOS

```bash
cd /path/to/Jelly
swift build -c release --product PersonalCalendar
./Scripts/build-app.sh
open dist/Jelly.app
```

Local outputs: `dist/Jelly.app`, `dist/Jelly.app.zip`, `dist/Jelly.dmg`.

### iOS

Open `iOS/Jelly.xcodeproj`, select the `Jelly-iOS` scheme and an iPhone simulator, then Run. Full Xcode 26+ with Swift 6.2 and an installed iOS Simulator runtime is required.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/build-ios.sh
```

Output: `dist/ios/Debug-iphonesimulator/Jelly.app`. Device signing is configured separately in Xcode. Without an iOS SDK, `Scripts/test-ios-catalyst.sh` typechecks every iOS source for iOS 17 through Mac Catalyst. See the [iOS guide](iOS/README.md) for UI tests and the [validation record](docs/ios/验证记录.md) for evidence and remaining gaps.

## Data and installing a new build

Jelly keeps its data in `~/Library/Application Support/PersonalCalendar/`. To replace the installed `~/Applications/Jelly.app` with a reviewed build, use `Scripts/install-desktop-app-safely.sh`; it accepts only a signed Jelly app, creates verified app and data backups (`~/Applications/Jelly-backups/`, `~/Library/Application Support/Jelly-data-backups/`) before replacement, and stops without changing anything if Jelly is still running.

## Layout

| Path | Role |
|------|------|
| `Package.swift` | Shared libraries, desktop app and MCP bridge targets |
| `Sources/CalendarDomain`, `Sources/WorkspaceDomain` | Shared calendar and workspace rules |
| `Sources/CalendarPersistence` | Shared local JSON store, backups and recovery |
| `Sources/JellyMCP`, `Sources/JellyMCPBridge` | MCP protocol/service core and desktop stdio bridge |
| `Sources/CalendarApp` | Desktop SwiftUI/AppKit UI and application services reused by iOS |
| `iOS/Jelly` | Native mobile SwiftUI/UIKit UI and platform adapters |
| `iOS/Jelly.xcodeproj`, `iOS/shared-sources.txt` | iOS target and explicit references to shared application sources |
| `Tests/`, `iOS/Validation`, `iOS/JellyUITests` | Package tests, mobile shared-service smoke tests and simulator UI journeys |
| `Scripts/` | Desktop/iOS build and validation entry points |
| `Support/`, `iOS/Assets.xcassets` | Platform metadata and assets |
| `docs/ios/` | iOS scope, feature parity, decisions and validation evidence |
| `dist/` | Ignored local build products and validation outputs |

Keep both apps in this repository so domain and persistence changes can be reviewed together. The iOS project references selected `Sources/CalendarApp` files directly rather than copying them. When changing that shared set, update both `iOS/shared-sources.txt` and the Xcode project's Shared Sources/build phase; validate the affected desktop and mobile paths. See the [structure decision](docs/ios/开发记录.md#仓库组织与远端提交2026-09-27).

## Status

**macOS：** Workspace V1 已通过自动化门禁和隔离数据下的真实应用交互验收，可作为内部可用版本。公开发行仍需 Developer ID 签名、公证和安装升级演练；AI、摘要与知识库层不在 V1 范围内。完整证据见 [Workspace V1 验收记录](docs/validation/workspace-v3/acceptance.md)。

**iOS：** 真实 SDK 构建及 iPhone 模拟器三模块基础旅程已通过。完整功能复刻、真机、中文输入法与用户验收仍未完成；见[功能对照与验收](docs/ios/功能对照与验收.md)。
