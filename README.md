# Jelly

Personal productivity app for macOS.

**Now:** calendar and list-style items, structured Block notes, calendar–note relations, and a raw-first inspiration inbox.
**Also built in:** a built-in MCP server that exposes calendar/schedule operations to AI clients over loopback HTTP (plus a bundled `jelly-mcp` stdio bridge) — see [docs/Jelly-MCP.md](docs/Jelly-MCP.md).
**Next (not built yet):** AI-assisted processing, material digests into a personal knowledge base (source → digest → wiki-style notes), and related workflows.

Local-first. Data stays on your Mac.

## Download

Prebuilt installers are on **[GitHub Releases](https://github.com/adeptify/Jelly/releases/latest)** — not in this git tree (`dist/` is gitignored).

1. Open the latest release.
2. Download `Jelly.app.zip` (or `Jelly.dmg`).
3. Follow [docs/Jelly-安装说明.md](docs/Jelly-安装说明.md).

Requirements: Apple silicon Mac, macOS 14+. First launch uses Control-click → Open (ad-hoc signed).

## Build from source

```bash
cd /path/to/Jelly
swift build -c release --product PersonalCalendar
./Scripts/build-app.sh
open dist/Jelly.app
```

Local outputs: `dist/Jelly.app`, `dist/Jelly.app.zip`, `dist/Jelly.dmg`.

## Data and installing a new build

Jelly keeps its data in `~/Library/Application Support/PersonalCalendar/`. To replace the installed `~/Applications/Jelly.app` with a reviewed build, use `Scripts/install-desktop-app-safely.sh`; it accepts only a signed Jelly app, creates verified app and data backups (`~/Applications/Jelly-backups/`, `~/Library/Application Support/Jelly-data-backups/`) before replacement, and stops without changing anything if Jelly is still running.

## Layout

| Path | Role |
|------|------|
| `Sources/CalendarDomain` | Domain models, recurrence, reducer |
| `Sources/CalendarPersistence` | Local JSON store & backup |
| `Sources/CalendarApp` | SwiftUI / AppKit UI |
| `Tests/` | Unit tests |
| `Scripts/` | Build & packaging |
| `Support/` | `Info.plist`, app icon |
| `docs/` | Design, validation, install guide |

## Status

Workspace V1 已通过自动化门禁和隔离数据下的真实应用交互验收，可作为内部可用版本。公开发行仍需 Developer ID 签名、公证和安装升级演练；AI、摘要与知识库层不在 V1 范围内。完整证据见 [Workspace V1 验收记录](docs/validation/workspace-v3/acceptance.md)。
