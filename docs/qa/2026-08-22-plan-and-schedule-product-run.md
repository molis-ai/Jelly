# 「拆开并安排」产品实操记录

> 设计日期：2026-08-22
> 工程验证日期：2026-08-23
> 分支：`codex/jelly-goalboard-plan-and-schedule`
> Task 9 实现 HEAD：`0a01e58550b39c7f10461c90d6bc7e9bb714ea7c`
> 状态：工程验证通过；最终打包 App 的限定主流程产品实操通过；用户验收尚未完成

本文记录当前真实状态和证据边界。自动化测试绿不能代替打包 App 实操，限定主流程跑通也不能代替用户本人对 9 分体验的判断。

## 工程验证通过

- `git diff --check`：通过。
- Task 9 focused suites：166 tests / 5 suites 通过。覆盖非协作 timeout/cancel、迟到结果、说明编辑与真实私有剪贴板往返、相邻空标题 task 几何，以及真实 JSON apply / 重启 load / 同会话 undo 后再 load。
- Task 10 保存交接回归：`NoteAutosaveCoordinatorTests` 32/32、`NotesVerticalIntegrationTests` 18/18、`TaskBlockCalendarIntegrationTests` 10/10、`WorkspaceRouteTransitionTests` 6/6 通过；共享反馈与真实撤销、原生 finalizer 替换、编辑器会话交接的定向回归通过。
- `swift test`：全量退出 0。
- `swift build -c release --product PersonalCalendar`：通过。
- `./Scripts/verify-block-input-purity.sh --self-test` 与 `./Scripts/verify-block-input-purity.sh Sources/CalendarApp/Notes/BlockEditor`：均通过。实施计划原命令曾漏写必需参数，已在本文同一分支修正；不把那次 usage error 记成代码失败。
- `./Scripts/test-build-app-archive.sh`：通过。临时 ZIP 与只读 DMG 内是同一个严格签名 App。
- `./Scripts/build-app.sh`：通过，生成 `dist/Jelly.app`、`dist/Jelly.app.zip`、`dist/Jelly.dmg`。
- `codesign --verify --deep --strict --verbose=2 dist/Jelly.app`：通过。Identifier `com.oreal.personalcalendar`，ad-hoc 签名，CDHash `869c53ee577a07b3a58cd4c93c27603bd7e66b30`；这不是公证发行证明。
- 最终产物 SHA-256：可执行文件 `f76d416f7d9aba84ea496105d730e5b0fc01aa16958312041728f248bd473373`；ZIP `43ddf8d3792a8ba7b17ce99ea7df27e0df2a27f39dfea7b2ce21029ac1498985`；DMG `eea2956edc0c8e63d3ed3b7eeba14343ca92b23bb97f600333be07c64746adba`。

以上工程证据本身只能说明工程验证通过，不能单凭这些证据声称 9 分体验、产品实操通过或用户验收通过。

## 限定范围的产品实操通过

Codex 于 2026-08-23 从最终 `dist/Jelly.app` 启动，使用独立数据目录和一条真实中文笔记走通以下路径：

- 笔记“把牙医检查安排好”包含连续中文正文。当前设备不支持本地 Apple 智能拆解，界面明确提示并保留手动添加与安排能力，没有把不可用状态伪装成成功。
- 手动创建两个可独立完成的行动和完成说明，安排其中一个后提交。界面出现“已创建 2 个行动，并安排其中 1 个”的可见反馈；点击真实“撤销”按钮后，两项行动、日历项和 links 一并移除，原始段落保留，操作日志无未恢复记录。
- 再次创建行动“确认牙科可预约时间并完成预约”，附完成说明并安排到日历。切换到日历可见该事项，标记完成后回到笔记，任务勾选、删除线和完成说明同步更新，未出现保存错误。
- 正常退出并从同一个最终 App、同一个隔离数据目录重启。没有出现恢复提示；原始标题、正文、已完成任务、完成说明、一个日历安排与 link 均保留。

这证明最终打包 App 的“手动拆开 → 微调 → 安排 → 提交 → 整单撤销 / 日历完成回写 → 重启恢复”限定主流程已实操通过。没有覆盖真实系统模型生成质量、真实历史大数据量、所有取消与冲突分支，因此不能扩大为整体 9 分体验或完整产品验收。

## UNVERIFIED

- 真实 Apple 系统模型的问题质量、行动可独立完成程度、完成说明可观察性；当前机器能力不可用，已验证的是清楚降级与手动路径
- 中文 IME 候选窗与真实输入手感
- VoiceOver 连续听感
- 主观视觉是否安静清楚、时间建议是否制造压力
- 真实历史数据量下的长时间连续使用，以及未逐条实操的取消、超时、局部重拆与时间冲突分支

## 用户验收

待用户本人完成一个真实小事和一个需要继续拆开的长想法。用户未明确认可前，不能记录用户验收通过。
