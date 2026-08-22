# 「拆开并安排」产品实操记录

> 日期：2026-08-22
> 分支：`codex/jelly-goalboard-plan-and-schedule`
> 状态：工程修复进行中，尚未完成全量门禁、打包实操与用户验收

本文只记录当前真实状态和待填证据。自动化测试绿不能代替打包 App 实操；Codex 完成打包与真实路径实操后再补证据。

## 工程验证

- HEAD 在实现 Task 9 边界修复时尚未提交。
- 本轮只要求跑 focused tests 与 `git diff --check`，不声称全量 `swift test`、Release、打包或签名已通过。
- 已覆盖并实现的工程边界：非协作 planner 的 timeout/cancel 及时返回且迟到结果丢弃；`completionDescription` 在复用原 task BlockID 的编辑/粘贴路径上保留；相邻空标题 task 的说明 overlay 不再互相覆盖；真实 JSON 文件上的 apply / 重启 load / 同会话 undo 后再 load。
- 待 Codex 补：全量测试、`swift build -c release --product PersonalCalendar`、`./Scripts/build-app.sh`、codesign，以及完整命令与产物哈希。

## 产品实操

尚未用最终打包 App、真实中文笔记和已有日历数据走主流程。不得把单元测试或 scripted planner 记成产品实操通过。

待 Codex 用隔离数据目录启动最终包后补：

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
