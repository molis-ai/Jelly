# 「拆开并安排」产品实操记录

> 设计日期：2026-08-22
> 工程验证日期：2026-08-23
> MiniMax-M3 真实回归日期：2026-08-24
> 视觉重做与最新 App 实操日期：2026-08-24
> 分支：`codex/jelly-goalboard-plan-and-schedule`
> 此前最终打包 App / 产品实操对应代码：`75a59dd56f9fa3264d9136230deced96d27188e0`
> 最新视觉重做基线：`75cbc21`；语义收紧对应当前分支本文件所在候选；已重新生成并实操 `dist/Jelly.app`
> 状态：最新候选除一个已在 `75cbc21` 基线复现的无关既有测试失败外，工程门禁通过；当前设备可覆盖的手动产品实操与 MiniMax-M3 代理语义回归通过；真实 Apple 模型与用户验收尚未完成

本文记录当前真实状态和证据边界。自动化测试绿不能代替打包 App 实操，限定主流程跑通也不能代替用户本人对 9 分体验的判断。MiniMax 真实调用不能代替 Apple Foundation Models 在最终 App 中的可用性或质量。

## 工程验证（候选通过，已知基线失败）

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
- 2026-08-24 视觉重做后的全量 `swift test` 退出 0；`DecompositionWorkbenchPresentationTests` 与 `DecompositionWorkbenchInteractionTests` 定向套件通过，覆盖窄窗全宽行动行、紧凑来源区、克制主按钮、长快捷回答、完整 Tab 旅程、关闭/停止语义和覆盖人工时间前确认。
- 2026-08-24 语义收紧后的最新全量 `swift test` 有且只有 `BlockEditorUndoTests/hostedLinkButtonRemovesTheLinkAtItsCollapsedCaretWithoutPromptingAgain` 失败 3 项；在从 `75cbc21` 导出的全新基线目录中运行同一测试，得到完全相同的 3 项失败，因此不把它归因于本候选。排除该既有失败后，其余全量测试退出 0；本候选涉及的 prompt contract、validator/reducer 与 MiniMax live support 定向回归均通过。
- 2026-08-24 最新 `./Scripts/build-app.sh`、release build、purity 自测/扫描与 `./Scripts/test-build-app-archive.sh` 均通过。临时 ZIP 与只读 DMG 中是同一个严格签名 App，archive regression CDHash 为 `f03dea48eb0c0e584ac4763e64975f775db05ffc`。
- 最新 `dist/Jelly.app` 严格签名校验通过。Identifier `com.oreal.personalcalendar`，ad-hoc 签名，CDHash `2abb1e5ef2d8e2778926f494a4ab726db6608c22`；这不是公证发行证明。
- 2026-08-24 最新产物 SHA-256：可执行文件 `PersonalCalendar` 为 `6c339f28c99c64e1edb47a2c03f84a9b37594e83897fefe2dbcd7f80831fc33a`；ZIP `5b93c8e161a1961b0a035f70f360e40b2f61997dbe0ac7d8433cf56ad6d75495`；DMG `413fbd67357b1baf42f3b79ea9b650aaebe28df6726e8fb77fb7ea909bce7298`。

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

这证明 `75a59dd` 当时最终打包 App 的“整篇或选区进入 → 手动拆开 → 键盘微调/排序 → 日期/时间/时长微调 → 安排 → 提交 → 跨页面回写 → 精确撤销 → 多篇连续使用 → 代表性日历共存 → 重启恢复”在当前设备可覆盖的范围内已实操通过。真实模型不可用，因此智能提问、无需追问、重试和局部重拆不能用手动结果代替；工作台打开后的外部笔记变化和建议生成后的晚到日历冲突有工程回归，但本轮未用两个最终 App 实例逐条实操。以上边界仍不允许把结果扩大成完整 9 分体验或用户验收。最新视觉重做后的补充实操见下一节。

## 2026-08-24 视觉否决后的重做与最新 App 实操

用户查看旧候选的真实安排页后明确反馈“太丑了”，因此旧候选的视觉用户验收直接记为失败，不用此前的工程绿测覆盖这个结论。留存对照：

- [用户否决的旧版截图](artifacts/2026-08-24-plan-and-schedule-before.png)
- [最新候选勾选一个日历行动后的截图](artifacts/2026-08-24-plan-and-schedule-after.jpeg)

复杂度审查后的最小完整重做没有引入新的页面、设计系统或布局框架，只收束当前工作台：

- 窄窗的来源区在“拆开 / 安排”阶段固定为 168 pt，长来源继续可滚动和展开，不再占据接近一半工作台。
- 两张缩在左侧的窄卡改为单列全宽行动行。行动标题和完成说明在左，“加入日历”在右；勾选后日期、时间和时长在行内下层展开。
- 行动容器改用已有 `theme.canvas` 与 0.5 pt 边线，在来源、安排背景和行动本身之间形成清楚但克制的三层区分。
- 底部不再重复两遍长句：左侧只显示“2 个行动 · 1 个日历安排”，右侧 200 pt 主按钮显示“创建并安排”；完整数量语义仍保留在无障碍标签中。
- 较长的模型快捷回答改为纵向单列，避免窄栏挤压；关闭运行中请求会先停止再进入正常关闭/丢弃流程；覆盖人工调整过的时间前增加明确确认。
- 双列卡片方案在开发中被否决：它会破坏原生 AppKit Tab 焦点链。最终采用单列全宽行动行，并给安排阶段的首个日历开关补上不抢占现有编辑焦点的初始焦点恢复；完整键盘旅程重新通过。

Codex 从最新 `dist/Jelly.app` 启动，使用独立目录 `jelly-ninepoint-final.vMd5ZH` 和代表性中文笔记“搬家前把生活安排稳妥”完成了以下真实路径：

- 在手动降级模式中填写两项行动及完成说明，进入安排页；真实截图确认来源区、全宽行动行、右对齐开关、展开后的日期/时间/时长和底部主按钮没有重叠、截断或大片失衡留白。
- 只把“确认旧房交接日期”加入日历，底部摘要立即变为“2 个行动 · 1 个日历安排”，可见主按钮为“创建并安排”。
- 提交后笔记出现两项 Task Block 与各自完成说明；“日历安排 · 1”弹层只列出被勾选的“确认旧房交接日期”。
- 点击真实“撤销本次拆开并安排”后，两项 Task Block、完成说明和日历安排全部移除，三段原始正文保持不变。

最新候选的手动主路径、真实展开态、提交写回和精确撤销达到当前设备可覆盖的产品实操标准。主观视觉是否达到用户要求的 9 分仍只能由用户本人确认；当前结论是“新候选可交用户验收”，不是“用户验收通过”。

语义收紧并重新打包后，Codex 又从当前 `dist/Jelly.app` 启动，使用独立目录 `jelly-final-app3.uIJ6Lg/data` 和中文笔记“搬家前把安排变成行动”复跑最终候选：

- App 确认只有隔离数据，没有读取或改写用户正在使用的 Jelly 数据；设备无 Apple 智能模型时明确降级，不伪装为智能拆解成功。
- 手动建立“确认旧房交接日期”和“联系两家搬家公司获取书面报价”，每项都有可观察的完成说明；只把第一项加入日历，提交反馈准确显示“已创建 2 个行动，并安排其中 1 个”。
- 写回后无障碍树和落盘 JSON 一致：原始三段逐字保留，新增 2 个 Task Block、1 个 Calendar Item 和 1 个 TaskBlockCalendarLink；draft journal 的 `records` 为空。
- 点击“撤销本次拆开并安排”后，Calendar Item、两个 Task Block 和 link 全部移除；原始三段仍逐字保留，落盘计数为 1 篇笔记、0 个日历项、0 个 link，journal 仍为空。

这轮覆盖的是最新重新打包 App 的手动降级闭环；Apple Foundation Models 的真实提问、初始拆解、刷新、局部重拆和修复仍不能由这条手动路径代替。

## 2026-08-24 MiniMax-M3 真实回归

本次只在测试轨上用 MiniMax-M3 复用 Jelly production prompt 与真实 `DecompositionOutputValidator` / `DecompositionDraftReducer`。生产 App 仍只装配 Apple Foundation Models；client 与 runner 不进入 `Sources`。

- 日期：2026-08-24
- 模型：`MiniMax-M3`
- 国内 base：`https://api.minimaxi.com/anthropic`
- Runner：`Scripts/test-decomposition-minimax-live.sh`；`--self-test` 通过
- 取钥：先 `appkey list` 确认 name `minimax`，再同一条 shell `appkey exec minimax -- sh -c 'JELLY_MINIMAX_LIVE=1 JELLY_MINIMAX_BASE_URL=https://api.minimaxi.com/anthropic JELLY_MINIMAX_MODEL=MiniMax-M3 swift test --filter MiniMaxDecompositionLiveTests'`
- 密钥卫生：未使用 `appkey get`、未读 `~/.appkey/`；日志与提交不含 Authorization / key；self-test 证明 fake secret 不出现在 stdout/stderr

### 真实失败与 production prompt 收紧

真实失败原样保留，没有为了绿测重跑到偶然成功。除最早的结构问题外，继续按用户视角复审后还暴露了语义问题：

1. `locked_refresh` 首次失败：`DecompositionOutputError.unexpectedExistingIDs`。当时 production prompt 只要求不得覆盖 locked 字段，没有写出 `validateRefresh` 要求的 ID 集合不变量。随后只在非空 `existingCandidates` 时补上：每个现有 id 必须原样出现恰好一次；不得新增、省略、重复，也不得把 existingID 写成空或 null；locked 字段必须逐字保留。
2. 日程类追问失败：第二次 `specific_dental` 把「下周三」改问成精确日历日期；第三次 `specific_dental` 追问今天哪个开始时间，`vague_moving` 追问总天数。这些都不决定需要哪些行动。clarification 约束因此收成一条：追问只问会改变行动阶段或范围的当前事实，例如已经做了什么、目标对象是否已经落实；不得询问先做哪一块、优先级、日程、开始时间、精确日期或总时长；已有且可原样保留的日期、金额、名称不要追问。
3. `vague_moving` 返回 4 个快捷回答，超过产品和 UI 的 `prefix(3)`。同一条单问 instruction 改为：需要追问时只问一个关键问题，并最多给 3 个简短快捷回答；无需追问时不要给问题或快捷回答。
4. 模糊追问曾询问“先理清哪个不确定项”或用户偏好，甚至在事实仍未知时直接拆解；prompt 改为只收集一个会改变行动范围的事实状态，并写入明确反例和正例。
5. 初始拆解曾提前要求签约、付定金或下单，也曾凭空增加朋友、邻居、9 月 10 日、“整租”等来源没有给出的事实；候选现在必须从当前来源即可直接开始，不得假设协作者、地点、承诺、期限、偏好、规格或服务类型。
6. 候选曾互相依赖，例如先拿报价再比较、先保存房源再预约；现在每个候选必须独立可启动、在一次聚焦会话内完成，并用可观察结果收口，不得把其他候选的完成结果当作前置条件。
7. “总预算两万元”曾被错误分摊到房租、搬家公司或相加的备选报价；现在金额、日期、名称只能保留在来源明确限定的作用域，整体预算不得复制成单项预算或备选报价合计。若确实需要，可另建“分配预算”行动。
8. refresh 曾把 `completionDescription` 错写成 `completion`、改变候选数量或返回肉眼无变化的“刷新”；现在要求原有 ID 集合和数量精确保留、locked 字段逐字保留，并至少让一个未锁字段产生可见改善。
9. 局部重拆曾只返回 1 项，或为了凑数量加入比较、预约等下游任务；现在明确输出 2～5 项，2 项已经覆盖范围时就停止，不得填充下游工作。
10. repair 曾只修时长，却把行动语义退化为模糊“处理/落实”；修复输出现在仍需满足独立可执行、事实作用域和可观察完成标准。

以上全部是 production `DecompositionPromptBuilder` 契约收紧，没有放宽 validator，也没有在 test-only JSON 里偷加语义。

### 最终结构与语义套件

最终连续两次完整运行 `MiniMaxDecompositionLiveTests` 均为 9/9，其中每轮 6 次真实 MiniMax-M3 LLM 调用进入真实 validator/reducer；不是只重跑单个偶然通过的案例。初始拆解、修复、刷新、局部重拆和模糊追问还分别完成了连续 3 次定向重复：

| 案例 | 结构结果 |
|---|---|
| 模糊搬家追问 | PASS：直接询问“入住日期目前确定了吗？”一类事实状态，快捷回答 ≤3 |
| 具体牙科无需追问 | PASS |
| 搬家回答后的初始拆解 | PASS：候选可独立开始、没有提前签约/付款、没有虚构事实或预算泄漏 |
| locked 刷新 | PASS：ID 各一次，locked 字段经 `validateRefresh` + `mergeRefresh` 保留，未锁字段有可见改善 |
| 局部重拆 | PASS：返回 2～5 个同层级独立行动，没有下游填充 |
| invalidDuration(20) 修复 | PASS：时长合法，行动语义没有退化 |

同一 suite 的 3 条离线测试（零网络、prompt/JSON 合同、decoder 不校正非法时长）也通过。

### 人工语义复审

- 模糊追问：PASS。问题收集当前事实，不再把“先想哪个”抛回用户，也不会在关键事实未知时擅自往下拆。
- 具体输入与初始拆解：PASS。输出是用户此刻能直接做的动作，有可观察完成说明，不提前承诺或付款，不发明人物、地点、日期、偏好和规格。
- locked 刷新：PASS。数量和身份稳定，用户锁定内容不动，未锁内容确实变得更具体。
- 局部重拆：PASS。拆到同一层级的 2～5 个独立行动，够用即停，不用下游预约或比较凑数。
- 修复请求：PASS。修合法时长的同时保住直接动作、事实边界和完成标准。
- 金额与作用域：PASS。整体预算没有被误写成单项房租、搬家报价或备选总和。

MiniMax-M3 真实 LLM 调用与 Jelly production prompt/validator 的结构和九分候选语义门槛：PASS。
该结论是对 MiniMax-M3 代理模型在这些固定代表性场景中的证据，不代表 Apple Foundation Models 在最终 App 中可用、稳定或质量通过，也不代表用户本人已经给出 9 分。

## UNVERIFIED

- 真实 Apple 系统模型的问题质量、行动可独立完成程度、完成说明可观察性；当前机器能力不可用，已验证的是清楚降级与手动路径
- 真实模型下的无需追问、取消/重试、连续无效输出修复和局部重拆；当前设备不能可靠触发
- 工作台打开后的外部笔记变化，以及时间建议生成后的晚到日历冲突；工程回归通过，最终 App 双实例实操未完成
- 中文 IME 候选窗与真实输入手感
- VoiceOver 连续听感
- 浅色主题、减少动态效果，以及新版主观视觉是否达到 9 分、时间建议是否制造压力；本轮最新 App 已直接观察深色主题，但用户尚未验收新版
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
