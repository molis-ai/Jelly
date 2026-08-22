# 「拆开并安排」产品实操记录

> 设计日期：2026-08-22
> 工程验证日期：2026-08-23
> 分支：`codex/jelly-goalboard-plan-and-schedule`
> 工程验证 HEAD：`0a01e58550b39c7f10461c90d6bc7e9bb714ea7c`
> 状态：工程验证通过；产品实操、真实模型体验与用户验收尚未完成

本文只记录当前真实状态和待填证据。自动化测试绿不能代替打包 App 实操；Codex 完成打包与真实路径实操后再补证据。

## 工程验证通过

- `git diff --check origin/main...HEAD`：通过。
- Task 9 focused suites：166 tests / 5 suites 通过。覆盖非协作 timeout/cancel、迟到结果、说明编辑与真实私有剪贴板往返、相邻空标题 task 几何，以及真实 JSON apply / 重启 load / 同会话 undo 后再 load。
- `swift test`：全量退出 0。
- `swift build -c release --product PersonalCalendar`：通过。
- `./Scripts/verify-block-input-purity.sh --self-test` 与 `./Scripts/verify-block-input-purity.sh Sources/CalendarApp/Notes/BlockEditor`：均通过。实施计划原命令曾漏写必需参数，已在本文同一分支修正；不把那次 usage error 记成代码失败。
- `./Scripts/test-build-app-archive.sh`：通过。临时 ZIP 与只读 DMG 内是同一个严格签名 App。
- `./Scripts/build-app.sh`：通过，生成 `dist/Jelly.app`、`dist/Jelly.app.zip`、`dist/Jelly.dmg`。
- `codesign --verify --deep --strict --verbose=2 dist/Jelly.app`：通过。Identifier `com.oreal.personalcalendar`，ad-hoc 签名，CDHash `5c517be3d74d089d246870e2a28aa5eea3faea2b`；这不是公证发行证明。
- SHA-256：可执行文件 `ec5044f81839b455a8c6d34ba5013cb857f84f3d188cb1e8464a910011a8eb09`；ZIP `1470be8fda22615aa9e98d2f311196237f20ce3ec597caec0e2385da2d37f25d`；DMG `7da63eaffa8b66d1e68380a05f335655e5d74581d13db8aa289269d3378389d3`。

以上只能说明工程验证通过，不能据此声称 9 分体验、产品实操通过或用户验收通过。

## 产品实操

尚未用最终打包 App、真实中文笔记和已有日历数据走主流程。不得把单元测试或 scripted planner 记成产品实操通过。

待 Codex 用隔离数据目录启动上述最终包后补：

- 智能拆解主流程与无需追问流程
- 取消、手动模式、局部重拆
- 时间冲突与整单撤销
- 保存、关闭、重启后的 Task / 完成说明 / Calendar Item / links
- 连续使用与视觉分区

## UNVERIFIED

- 真实 Apple 系统模型的问题质量、行动可独立完成程度、完成说明可观察性
- 中文 IME 候选窗与真实输入手感
- VoiceOver 连续听感
- 主观视觉是否安静清楚、时间建议是否制造压力

## 用户验收

待用户本人完成一个真实小事和一个需要继续拆开的长想法。用户未明确认可前，不能记录用户验收通过。
