# 「拆开并安排」产品实操记录

> 设计日期：2026-08-22
> 工程验证日期：2026-08-23
> MiniMax-M3 真实回归日期：2026-08-24
> 分支：`codex/jelly-goalboard-plan-and-schedule`
> 此前最终打包 App / 产品实操对应代码：`75a59dd56f9fa3264d9136230deced96d27188e0`
> 当前分支已继续九分硬化与 MiniMax 回归，尚未对最新代码重打包最终 App
> 状态：`75a59dd` 当时的工程验证与设备可覆盖最终 App 产品实操仍有效；最新硬化未重打包，因此最新打包 App 为 UNVERIFIED；MiniMax-M3 结构回归见下文；真实 Apple 模型与用户验收尚未完成

本文记录当前真实状态和证据边界。自动化测试绿不能代替打包 App 实操，限定主流程跑通也不能代替用户本人对 9 分体验的判断。MiniMax 真实调用不能代替 Apple Foundation Models 在最终 App 中的可用性或质量。

## 工程验证通过

- `git diff --check`：通过。
- Codex 最终独立复审：直接检查 `origin/main...HEAD` 的模型输出信任边界、取消与迟到结果、来源陈旧、原子写入、日历冲突、生产装配、重复提交和精确撤销路径；本轮结果为 `0 Critical / 0 Important`。这不替代下方真实模型、IME、VoiceOver 与主观体验验收。
- Task 9 focused suites：166 tests / 5 suites 通过。覆盖非协作 timeout/cancel、迟到结果、说明编辑与真实私有剪贴板往返、相邻空标题 task 几何，以及真实 JSON apply / 重启 load / 同会话 undo 后再 load。
- Task 10 保存交接回归：`NoteAutosaveCoordinatorTests` 32/32、`NotesVerticalIntegrationTests` 18/18、`TaskBlockCalendarIntegrationTests` 10/10、`WorkspaceRouteTransitionTests` 6/6 通过；共享反馈与真实撤销、原生 finalizer 替换、编辑器会话交接的定向回归通过。
- `swift test`：全量退出 0。
- `swift build -c release --product PersonalCalendar`：通过。
- `./Scripts/verify-block-input-purity.sh --self-test` 与 `./Scripts/verify-block-input-purity.sh Sources/CalendarApp/Notes/BlockEditor`：均通过。实施计划原命令曾漏写必需参数，已在本文同一分支修正；不把那次 usage error 记成代码失败。
- `./Scripts/test-build-app-archive.sh`：通过。临时 ZIP 与只读 DMG 内是同一个严格签名 App。
- `./Scripts/build-app.sh`：通过，生成 `dist/Jelly.app`、`dist/Jelly.app.zip`、`dist/Jelly.dmg`。
- `codesign --verify --deep --strict --verbose=2 dist/Jelly.app`：通过。Identifier `com.oreal.personalcalendar`，ad-hoc 签名，CDHash `869c53ee577a07b3a58cd4c93c27603bd7e66b30`；这不是公证发行证明。
- 2026-08-23 最终重打包产物 SHA-256：可执行文件 `f76d416f7d9aba84ea496105d730e5b0fc01aa16958312041728f248bd473373`；ZIP `7535ad5602356ea93b4f4374c712054cf1175149b565a55f2144d54250e17f19`；DMG `5928e3dd26dfd792da8095f53d1141fab09d079003115130d2c8846cf1c5b5df`。

以上工程证据本身只能说明工程验证通过，不能单凭这些证据声称 9 分体验、产品实操通过或用户验收通过。

## 当前设备可覆盖的产品实操通过

Codex 于 2026-08-23 从最终 `dist/Jelly.app` 启动，使用独立数据目录和一条真实中文笔记走通以下路径：

- 笔记“把牙医检查安排好”包含连续中文正文。当前设备不支持本地 Apple 智能拆解，界面明确提示并保留手动添加与安排能力，没有把不可用状态伪装成成功。
- 手动创建两个可独立完成的行动和完成说明，安排其中一个后提交。界面出现“已创建 2 个行动，并安排其中 1 个”的可见反馈；点击真实“撤销”按钮后，两项行动、日历项和 links 一并移除，原始段落保留，操作日志无未恢复记录。
- 再次创建行动“确认牙科可预约时间并完成预约”，附完成说明并安排到日历。切换到日历可见该事项，标记完成后回到笔记，任务勾选、删除线和完成说明同步更新，未出现保存错误。
- 正常退出并从同一个最终 App、同一个隔离数据目录重启。没有出现恢复提示；原始标题、正文、已完成任务、完成说明、一个日历安排与 link 均保留。

在同一个最终 App 上又用独立目录 `jelly-goalboard-audit.EEkuM9` 做了连续使用和代表性日历补验：

- 不重启 App 连续处理 6 篇长中文笔记，主题覆盖家庭来访、周末出行、搬家、体检、照片备份和公开分享。每篇都真实进入工作台、填写行动与完成说明并写回；其中一次先关闭工作台，确认没有产生 Task Block 或日历事项。
- 长计划中建立两项行动，真实执行顺序上移；工作台关闭、重新进入、安排和提交期间，正文与用户微调保持不变。
- 已有 09:15～09:45 的事项后，下一项建议为 09:45～10:15。随后通过 Jelly 日历界面加入一项全天事项和一项每周重复事项，再次拆开并安排时建议为 10:15～10:45；提交后原有两项、全天事项、每周事项和新事项都保留。
- 从日历返回笔记后点击真实撤销按钮，只移除了本轮行动，原始长中文正文、其他笔记与既有日历事项均保留。
- 把主窗口缩窄到约 916 px 后打开工作台，来源、行动草稿和底部确认区改为清楚的上下分区，正文没有被压成窄栏，12～16 pt 的字号层级没有出现突兀跳级。
- 正常退出后从同一个最终 App 和数据目录重启。6 篇笔记、完成说明、3 个相邻但不重叠的 Task 日历事项、1 个全天事项、1 个每周重复事项与 links 均重新可见；没有出现恢复 Sheet，draft journal 的 `records` 为空。

再用独立目录 `jelly-selection-audit.ser5RX` 验证选区与键盘路径：

- 三段中文正文中只选择第二段进入工作台，来源区只显示所选文字，前后两段没有混入模型上下文。第一次用 Tab 把焦点移到“关闭”，按空格关闭后没有写入，回到笔记时原选区仍保持。
- 再次从编辑器用 Tab 移到“拆开并安排”，按空格打开；随后只用 Tab / Shift-Tab、空格、普通按键与键盘粘贴完成添加行动、填写标题和完成说明、确认行动、勾选日历和最终提交。自动化工具不能合成真实中文 IME 候选过程，但普通 ASCII 按键和中文粘贴都进入正确字段。
- 提交后 Task Block 精确插在所选第二段之后，第三段仍在 Task 后面；没有把行动追加到整篇末尾，也没有改写三段原文。正常退出重启后，四段顺序、完成说明、Calendar Item 和 link 均保留，draft journal 的 `records` 为空。

最后用独立目录 `jelly-time-adjust-audit.34WQc9` 验证安排阶段的微调控制：

- 系统最初建议 8 月 23 日 09:45、30 分钟；在工作台内把日期改为 8 月 25 日、开始时间改为 16:30、时长改为 45 分钟，提交前摘要同步显示 16:30～17:15。
- 提交后 Jelly 日历精确显示 8 月 25 日 16:30～17:15，没有退回系统建议。日历标记完成后，笔记中的 Task 与相同 `completedAt` 同步完成，完成说明保持可见。
- 正常退出重启后，日期、开始与结束时间、完成状态、TaskBlockCalendarLink 都保留；JSON 中分钟值为 990～1035，draft journal 的 `records` 为空。

这证明最终打包 App 的“整篇或选区进入 → 手动拆开 → 键盘微调/排序 → 日期/时间/时长微调 → 安排 → 提交 → 跨页面回写 → 精确撤销 → 多篇连续使用 → 代表性日历共存 → 重启恢复”在当前设备可覆盖的范围内已实操通过。真实模型不可用，因此智能提问、无需追问、重试和局部重拆不能用手动结果代替；工作台打开后的外部笔记变化和建议生成后的晚到日历冲突有工程回归，但本轮未用两个最终 App 实例逐条实操。以上边界仍不允许把结果扩大成完整 9 分体验或用户验收。该实操证据绑定 `75a59dd` 当时的 `dist/Jelly.app`；其后的九分硬化与 MiniMax 回归尚未重打包，不能把本节写成最新代码的最终 App 实操。

## 2026-08-24 MiniMax-M3 真实回归

本次只在测试轨上用 MiniMax-M3 复用 Jelly production prompt 与真实 `DecompositionOutputValidator` / `DecompositionDraftReducer`。生产 App 仍只装配 Apple Foundation Models；client 与 runner 不进入 `Sources`。

- 日期：2026-08-24
- 模型：`MiniMax-M3`
- 国内 base：`https://api.minimaxi.com/anthropic`
- Runner：`Scripts/test-decomposition-minimax-live.sh`；`--self-test` 通过
- 取钥：先 `appkey list` 确认 name `minimax`，再同一条 shell `appkey exec minimax -- sh -c 'JELLY_MINIMAX_LIVE=1 JELLY_MINIMAX_BASE_URL=https://api.minimaxi.com/anthropic JELLY_MINIMAX_MODEL=MiniMax-M3 swift test --filter MiniMaxDecompositionLiveTests'`
- 密钥卫生：未使用 `appkey get`、未读 `~/.appkey/`；日志与提交不含 Authorization / key；self-test 证明 fake secret 不出现在 stdout/stderr

### 首次真实失败与 production prompt 收紧

首次真实结果原样保留，没有为了绿测重跑到偶然成功：

1. `locked_refresh` 首次失败：`DecompositionOutputError.unexpectedExistingIDs`。当时 production prompt 只要求不得覆盖 locked 字段，没有写出 `validateRefresh` 要求的 ID 集合不变量。随后只在非空 `existingCandidates` 时补上：每个现有 id 必须原样出现恰好一次；不得新增、省略、重复，也不得把 existingID 写成空或 null；locked 字段必须逐字保留。
2. 日程类追问失败：第二次 `specific_dental` 把「下周三」改问成精确日历日期；第三次 `specific_dental` 追问今天哪个开始时间，`vague_moving` 追问总天数。这些都不决定需要哪些行动。clarification 约束因此收成一条：追问只问会改变行动阶段或范围的当前事实，例如已经做了什么、目标对象是否已经落实；不得询问先做哪一块、优先级、日程、开始时间、精确日期或总时长；已有且可原样保留的日期、金额、名称不要追问。
3. `vague_moving` 返回 4 个快捷回答，超过产品和 UI 的 `prefix(3)`。同一条单问 instruction 改为：需要追问时只问一个关键问题，并最多给 3 个简短快捷回答；无需追问时不要给问题或快捷回答。

以上全部是 production `DecompositionPromptBuilder` 契约收紧，没有放宽 validator，也没有在 test-only JSON 里偷加语义。

### 最终结构套件

最终 `MiniMaxDecompositionLiveTests` 为 9/9，其中 6 次真实 MiniMax-M3 LLM 调用进入真实 validator/reducer：

| 案例 | 结构结果 |
|---|---|
| 模糊搬家追问 | 结构 PASS（`needsFollowUp`，question 非空，快捷回答 ≤3） |
| 具体牙科无需追问 | PASS |
| 搬家回答后的初始拆解 | PASS |
| locked 刷新 | PASS（ID 各一次，locked 字段经 `validateRefresh` + `mergeRefresh` 保留） |
| 局部重拆 | PASS |
| invalidDuration(20) 修复 | PASS |

同一 suite 的 3 条离线测试（零网络、prompt/JSON 合同、decoder 不校正非法时长）也通过。

### 人工语义复审

- 具体牙科无需追问：PASS
- 初始拆解：PASS
- locked 刷新：PASS
- 局部重拆：PASS
- 修复请求：PASS
- 模糊搬家追问：「你现在更想先理清哪个不确定项：入住日期还是预算？」可用，但问的是澄清顺序，而不是直接收集当前事实，约 8/10，因此九分语义门槛 FAIL。

MiniMax-M3 真实 LLM 调用与 Jelly production prompt/validator 回归：PASS。
九分语义门槛：FAIL。模糊搬家追问「你现在更想先理清哪个不确定项：入住日期还是预算？」可用，但问的是澄清顺序而不是直接收集当前事实，约 8/10。
该证据不代表 Apple Foundation Models 在最终 App 中可用或质量通过。

## UNVERIFIED

- 最新硬化后的最终打包 App 与产品实操；当前仍沿用 `75a59dd` 当时的 dist 产物，尚未重打包
- 真实 Apple 系统模型的问题质量、行动可独立完成程度、完成说明可观察性；当前机器能力不可用，已验证的是清楚降级与手动路径
- 真实模型下的无需追问、取消/重试、连续无效输出修复和局部重拆；当前设备不能可靠触发
- 工作台打开后的外部笔记变化，以及时间建议生成后的晚到日历冲突；工程回归通过，最终 App 双实例实操未完成
- 中文 IME 候选窗与真实输入手感
- VoiceOver 连续听感
- 深色主题、减少动态效果，以及主观视觉是否安静清楚、时间建议是否制造压力
- 真实历史大数据量下的长时间连续使用；本轮直接覆盖的是单次会话 6 篇长中文笔记

## 用户验收

> 状态：待用户本人完成。以下内容是验收入口，不是代填的签字；用户未明确认可前，不能记录用户验收通过。

### 旅程 A：一个最近真的要处理的小事

1. 在自己的正常 Jelly 数据中，新建或打开一篇最近确实要处理的中文小事。
2. 点击「拆开并安排」。若真实系统模型可用，观察问题是否真的改变拆法；若界面诚实降级到手动模式，直接添加两个可独立完成的行动。
3. 至少修改一次行动标题、完成说明、日期、开始时间或时长，只安排真正需要进入日历的行动。
4. 提交后到日历确认时间，再回到笔记确认原文、行动和完成说明；正常退出并重开一次 Jelly。
5. 判断：微调是否顺手，时间建议是否让人有压力，这条路径是否比自己从头拆解更容易开始。

### 旅程 B：一个需要继续拆开的长想法

1. 使用一篇至少三段、混有背景和约束的真实长想法；先只选择其中一段进入工作台，确认来源没有混入前后段落。
2. 先关闭一次工作台，确认没有写入；重新进入后使用一次「继续拆开」，再做排序、删除或取消选择。
3. 只创建愿意承担的行动，只安排其中一部分；确认 Jelly 没有要求接受全部建议，也没有改写原文。
4. 提交后检查笔记与日历，再尝试一次完成反馈里的「撤销」，确认控制感和后悔成本是否合适。
5. 判断：三分区能否一眼看懂，长内容是否舒服，视觉是否安静，整个过程是否让人更愿意行动而不是更焦虑。

### 请用户本人反馈

```text
总体验（0～10）：
问题是否有用：
微调是否顺手：
时间建议是否制造压力：
视觉是否安静清楚：
最舒服的一处：
最卡的一处：
结论：通过 / 不通过
```

只有用户本人明确给出「通过」或等价认可，才更新本节并关闭 9 分体验 Goal；若不通过，把「最卡的一处」变成新的可复现失败场景继续修。
