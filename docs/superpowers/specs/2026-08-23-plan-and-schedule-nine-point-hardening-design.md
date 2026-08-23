# 「拆开并安排」九分体验硬化设计

> 日期：2026-08-23
> 状态：方向已获用户确认；待实施与最终 App 验收
> 基线：`codex/jelly-goalboard-plan-and-schedule` / `0c17dd4`
> 前置规格：`docs/superpowers/specs/2026-08-22-plan-and-schedule-design.md`

## 1. 结论与边界

本轮不增加新的目标管理能力，也不改变 GoalBoard / Jelly 的责任边界。目标是把已经成立的「来源 → 拆开 → 安排 → 原子提交 → 撤销」闭环从约 8.5 分收口为 9 分候选。

MiniMax-M3 只用于真实 LLM 调用和输出质量回归。生产 App 仍只装配 Apple Foundation Models；不得加入 MiniMax provider、环境变量开关、网络权限说明、密钥读取或第二套生产调用链。MiniMax 证据不能写成 Apple 本地模型产品实操通过。

九分仍分三层：

1. 工程验证通过：测试、构建、签名和静态审查通过。
2. 产品实操通过：最终 App 在真实中文、真实日历、失败恢复、深浅主题、连续使用等旅程中通过。
3. 用户验收通过：用户本人明确认可。真人才能判断的中文 IME、VoiceOver 连续听感和主观视觉不得由自动化代签。

## 2. 复杂度必要性审查

### 当前必须

- 自由回答有可点击的「继续」，不要求用户猜 Return。
- 有意义的工作台草稿关闭前防误丢；模型运行时第一次 Escape 只停止请求。
- 手动降级直接准备第一项可输入行动，并把焦点放在标题。
- 来源标明「所选文字 / 整篇笔记」，默认克制、需要时可完整展开。
- 用户调整过的时间不会被普通「重新建议」覆盖。
- 没有建议时不显示会被误认成建议的默认 09:00。
- 行动、安排、来源和确认区域有更强但克制的模块区分；字号继续限制在 12～16 pt。
- 单行 AppKit 输入更新与多行输入一样保护 marked text。
- 最终 App 覆盖双实例冲突、深色、减少动态、连续使用以及可观察的无障碍路径。
- MiniMax-M3 真实请求复用 production prompt 和 validator，固定一组中文回归样例。

### 可以延后

- 工作台草稿跨 App 重启持久化。
- 超大历史数据专项优化；只有代表性实操出现可感知问题才启动。
- 批量编辑、全选、候选跳转等高级加速器。
- Apple 提示词的 provider 特定优化；必须等真实 Apple 模型证据。

### 应当删除

- MiniMax 或 Prologue 进入 production composition。
- 新建通用工作流引擎、第二份候选状态机或新的持久化子系统。
- GoalBoard 同步、目标树或目标真相源能力。
- 为追求分数进行与观察问题无关的全页重构。

## 3. 用户旅程

### 3.1 智能模式

用户打开工作台后首先看见功能名、三阶段和来源边界。若模型需要追问，输入框右侧始终有「继续」；Return 与点击完全等价。模型运行时显示当前正在整理并提供「停止」。

模型返回后，用户一次只编辑一个展开行动。每项清楚回答三件事：是否创建、行动是什么、做到什么算完成。排序、删除和继续拆开仍可用，但视觉上归入次级操作，不与内容输入争抢注意力。

### 3.2 手动模式

模型不可用或失败时，来源区出现一个可辨认但不夸张的状态块，解释真实原因并明确「仍可手动完成」。右侧自动出现第一项空行动，标题获得焦点；用户无需先理解「至少保留一个行动」或额外点击「添加行动」。

### 3.3 安排模式

每项行动默认只决定「是否加入日历」。加入后：

- 有建议时显示建议摘要和可编辑控件。
- 没有建议时只显示「选择日期与时间」，不展示隐性 09:00。
- 用户修改日期、时间或已存在 proposal 的时长后，该安排被标为人工调整。
- 「重新建议时间」默认只更新未调整项；存在人工调整项时，次级菜单才提供「全部重新建议」，并明确会覆盖人工调整。

### 3.4 关闭与失败

- 无内容、无候选、无用户进展：关闭立即生效。
- 模型请求运行中：第一次 Escape 只停止请求；再次关闭按当前草稿状态处理。
- 已有回答、候选或安排：关闭弹出「继续编辑 / 丢弃这次拆解」。不做隐式保存，也不假装草稿会跨重启保留。
- 日历晚到冲突：整单不写入，保留候选和人工时间，错误紧邻确认区并提供重新建议或取消加入日历的路径。
- 来源变化：整单不写入，当前草稿保持可查看。先用最终 App 双实例复现；本轮不做自动文本合并。若必须离开，丢弃确认要明确说明草稿不会保存。
- 持久化失败：原笔记和日历不变，草稿仍在当前工作台，允许重试。

## 4. 视觉和交互

### 顶部

左侧显示「拆开并安排」，其后是「理解 / 拆开 / 安排」步骤；当前步骤有清楚选中态，已完成步骤降低权重。关闭仍在最右侧。

### 来源模块

保留暖纸色 `conversationSurface`，增加来源类型标签和展开控制。手动/失败状态使用同一语义色系的浅色块与细边框，不引入渐变、大标题或装饰插画。

### 行动模块

继续使用 15 pt 分区标题、14 pt 行动标题、12 pt 完成说明。选中行用现有 `selectionFill`、`selectionOutline` 和 `CalendarTheme.cornerRadius` 建立边界；未选中行保持平静。内容输入与次级操作分成两行，单屏同时显著的选择不超过四类。

完成说明的可见提示改成「做到什么算完成？」；AX label 仍明确说明字段含义。创建选择必须有可理解的可见语义，不只剩一个无标题 checkbox。

### 安排模块

每个行动形成清楚的垂直组：行动摘要、是否加入日历、时间状态、时间控件。使用现有 surface / separator / outline token，不新增设计系统。

### 底部确认区

继续保持固定高度和精确计数。阻塞错误既在底部说明，也把对应字段/行动置为当前项；最终主按钮仍用「创建 N 个行动，并安排其中 M 个」。

## 5. MiniMax-M3 测试专用路径

### 5.1 调用边界

- 钥匙名：`minimax`；环境变量：`MINIMAX_API_KEY`。
- 运行必须使用同一条 shell：`appkey exec minimax -- ...`。
- 默认模型：`MiniMax-M3`。
- 默认 base URL：`https://api.minimaxi.com/anthropic`。
- 测试客户端只存在于 `Tests/CalendarAppTests`；使用 ephemeral `URLSession`，不打印请求头和密钥。
- 普通 `swift test` 不发网络请求；只有 `JELLY_MINIMAX_LIVE=1` 才执行 live suite。

### 5.2 结构等价

测试 harness 在 production prompt 之后附加与 Apple `GenerationSchema` 等价的 JSON 返回合同：

- clarification：`needsFollowUp`、`question`、`quickAnswers`。
- candidates / split：`actions[]`，每项含 `existingID`、`title`、`completionDescription`、`estimatedMinutes`。

解析后必须进入真实 `DecompositionOutputValidator` 或 `DecompositionDraftReducer`；测试不得用另一套宽松 validator 把失败洗绿。

### 5.3 固定样例

至少覆盖：

1. 模糊小事：应提出一个会改变拆法的问题，quick answers 不超过 3。
2. 已足够具体的行动：应明确无需追问。
3. 回答后的初始拆解：2～5 项，标题可执行、完成说明可观察、时长合法。
4. 有 locked 字段的刷新：输出带齐 existing IDs，真实 reducer 保留人工字段。
5. 局部重拆：只返回目标的 2～5 个子行动，不携带 existing ID。
6. 带 validation feedback 的修复：第二次输出通过真实 validator。

Live suite 输出安全的案例名、模型名、耗时、结构结果和候选正文，便于 Codex 做中文质量复审；不得输出 Authorization header 或 key。

## 6. 非目标

- 不把 MiniMax 测试结果写成 Apple Foundation Models 的速度、可用性或 UI 证据。
- 不改变 Jelly 本地优先与离线生产运行属性。
- 不增加 GoalBoard 数据读取、同步或目标管理。
- 不在本轮引入工作台 draft repository。
- 不以 detector `[]` 声称 SwiftUI 视觉通过。

## 7. 验收

### 工程门禁

- 新测试先红后绿；所有 focused suites 与全量 `swift test` 通过。
- Release build、App 打包、归档一致性、严格 codesign 通过。
- production source 不出现 `MINIMAX_API_KEY`、`api.minimaxi.com`、`MiniMax-M3` 或测试 provider。
- 普通测试在没有密钥时不联网、不失败。

### MiniMax 真实回归

- 使用 `appkey exec minimax` 跑固定 6 类样例。
- 所有结构进入真实 validator；无伪造或手工修补结果。
- Codex 独立检查问题是否有用、行动是否独立、完成说明是否可观察、局部重拆是否越界。
- 该结论写作「MiniMax-M3 真实 LLM 质量回归通过/未通过」，不写 Apple 产品实操通过。

### 最终 App 产品实操

- 手动降级打开即能输入；自由回答可点击继续。
- 编辑候选与时间后误按 Escape 不丢草稿。
- 长来源可展开并标明范围。
- 人工时间普通刷新后保持；全部刷新需要明确动作。
- 无建议不显示伪时间。
- 双实例来源变化和晚到日历冲突无半写，草稿保持可查看。
- 深浅主题、窄窗口、Reduce Motion、6 篇长中文连续使用重走。
- 中文 IME 候选、VoiceOver 连续听感和主观视觉由用户本人验收；未验收前保持 `UNVERIFIED`。
