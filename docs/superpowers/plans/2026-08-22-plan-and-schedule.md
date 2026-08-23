# Jelly「拆开并安排」Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Jelly 内完成一条从真实笔记意图到 2～5 个可微调行动、再到可选日历安排的纵向闭环；GoalBoard 不进入产品和数据层，用户最终确认前不产生持久写入。

**Architecture:** `WorkspaceDomain` 只新增 Task Block 完成说明和一个原子 `applyDecompositionPlan` 写入合同；所有问答、候选、请求状态和时间建议都留在 `CalendarApp/Decomposition` 的临时工作台中。Apple Foundation Models 只实现 Jelly 自有的窄 `DecompositionPlanning` 协议，确定性排期引擎和 Workspace reducer 才有资格构造、校验并写入 Calendar Item。

**Tech Stack:** Swift 6.3、SwiftUI、AppKit/TextKit 1、Observation、Swift Testing、现有 `CalendarDomain` / `WorkspaceDomain` / `CalendarPersistence`，macOS 26+ 条件启用 Apple `FoundationModels`，Jelly 最低系统仍为 macOS 14。

**Spec:** `docs/superpowers/specs/2026-08-22-plan-and-schedule-design.md`

## Global Constraints

- 实现只在 `/Users/oreal/adeptify-home/repos/Jelly/.worktrees/jelly-goalboard-plan-and-schedule` 的 `codex/jelly-goalboard-plan-and-schedule` 分支进行；不得改动主工作区里的用户未提交文件。
- Jelly 第一阶段吸收 GoalBoard 的判断纪律，不接入 GoalBoard 产品或数据；不连接、读取或写入 GoalBoard SQLite，不新增 Goal、目标树、目标入口或 GoalBoard ID。
- 支持选中文字或整篇笔记；空来源、跨 Block 文本选区、仍在中文 IME 组字或无法完成草稿保护时不得打开工作台。
- 一次只问一个会改变拆法的问题；初始输出严格为 2～5 个候选，每项标题和完成说明非空，时长只允许 `15 / 30 / 45 / 60 / 90` 分钟。
- 用户修改过的标题和完成说明分别锁定；刷新不得覆盖锁定字段；「继续拆开」只替换目标候选，其余候选的值、顺序和选择状态必须按字节等价保留。
- 候选和问答只存在内存中，关闭工作台或重启 App 后丢弃；最终确认前不得保存 Task Block、Calendar Item 或关系。
- 原文永远不改写：选区来源写回到所在 Block 后，整篇来源写回到笔记末尾。
- 只有用户选择安排的行动才创建 Calendar Item；模型没有 Workspace Store、日历写入或领域命令权限。
- 时间建议只看未来七个本地自然日、09:00～21:00、真实 timed Calendar Item/recurrence 和本轮已占用槽位；相同时取最早，不推断精力、工作时间或习惯。
- 模型不可用、语言不支持、取消、超时或连续两次结构无效时，保留用户内容并明确切到手动模式；Release 路径不得用 Mock 冒充生产模型。
- 最终写入必须是一次 Workspace transaction、一次 revision、一个 undo record；任一来源、锚点、ID、Task Block、Calendar Item、关系或冲突校验失败时整单不写。
- 工作台主字号限制为 12～16 pt；左侧暖灰澄清区、右侧白色行动区和底部确认区必须有清楚分区；窄窗口改为上下布局。
- 所有图标按钮提供中文 VoiceOver 名称和 help；键盘可完成进入、回答、切换、编辑、选择、返回和最终确认；模型返回不得抢走当前编辑焦点。
- 每个任务坚持 TDD：先写失败测试、确认失败原因、写最小实现、跑 focused tests，再做小提交。
- 自动化测试和构建通过只能叫“工程验证通过”。最终必须用打包后的 App、真实中文笔记、真实日历数据完成主流程、失败恢复、重启和连续使用；用户本人明确认可前不得声称“9 分体验”或“用户验收通过”。

---

## 当前执行状态（2026-08-23）

下文的复选框保留为原始 TDD 执行说明，不根据当前绿树倒推或伪造历史中的 RED 结果。当前状态以提交记录、测试输出和产品实操记录为准：

| 任务 | 当前状态 | 主要证据 |
| --- | --- | --- |
| Task 1 | 工程完成 | `86e8b19`、`7001800`；JSON / checksum / Markdown / HTML / 备份往返测试 |
| Task 2 | 工程完成 | `bc15305`、`2822039`；投影、长中文、主题与几何回归 |
| Task 3 | 工程完成 | `e970b5d`；来源捕获、候选校验、字段锁定与纯草稿 reducer 回归 |
| Task 4 | 工程完成 | `e4acf26`；共享半开区间冲突与七日建议引擎回归 |
| Task 5 | 工程完成 | `ce8f0dc`；原子写入、并发冲突、真实 JSON 重启与精确撤销回归 |
| Task 6 | 工程完成 | `b661769`、`a6e95a1`、`53dd917`；取消、迟到结果、有界修复、微调与手动降级回归 |
| Task 7 | 工程完成并完成当前设备实操 | `4283e01`、`75a59dd`；选区、键盘、三分区、窄窗口、跨页反馈与撤销实操 |
| Task 8 | 工程完成；真实模型质量 `UNVERIFIED` | `84034d2`；生产装配、系统能力检查、prompt 合同与真实 framework Release 编译 |
| Task 9 | 工程门禁和当前设备可覆盖实操完成；用户验收待完成 | `0a01e58`、`535487e`、`75a59dd`、`8a66515`、`52695a4`、`a55ac9d` 与 `docs/qa/2026-08-22-plan-and-schedule-product-run.md` |

---

## File Map

| 路径 | 单一责任 |
| --- | --- |
| `Sources/WorkspaceDomain/BlockDocument.swift` | Task Block 的可选完成说明及规范化 |
| `Sources/WorkspaceDomain/BlockMarkdownCodec.swift` | Jelly Markdown 完成说明元数据往返 |
| `Sources/WorkspaceDomain/BlockHTMLCodec.swift` | Jelly HTML 完成说明属性往返 |
| `Sources/CalendarApp/Notes/BlockEditor/TaskBlockCompletionDescriptionOverlay.swift` | 编辑器中的次级完成说明，不进入可编辑标题坐标 |
| `Sources/CalendarApp/Decomposition/DecompositionModels.swift` | 临时来源、候选、草稿、请求和错误类型 |
| `Sources/CalendarApp/Decomposition/DecompositionSourceCapture.swift` | 从同 Block 选区或整篇 Note 生成不可变来源快照 |
| `Sources/CalendarApp/Decomposition/DecompositionPlanning.swift` | Jelly 自有窄模型协议、输出校验和测试适配器 |
| `Sources/CalendarDomain/CalendarTimedOccupancy.swift` | 可由排期与 reducer 共同复用的 timed 冲突判断 |
| `Sources/CalendarApp/Decomposition/CalendarProposalEngine.swift` | 七日、09:00～21:00 的确定性建议 |
| `Sources/WorkspaceDomain/DecompositionWorkspaceCommand.swift` | 原子写入 payload、插入锚点和 typed conflict |
| `Sources/WorkspaceDomain/WorkspaceReducer+Decomposition.swift` | 一次性校验、插块、建日历项和关系 |
| `Sources/CalendarApp/Decomposition/DecompositionWorkbenchModel.swift` | 单活动请求、锁定字段、局部重拆、手动降级和提交编排 |
| `Sources/CalendarApp/Decomposition/DecompositionWorkbenchView.swift` | 三阶段工作台外壳、响应式分区和底部结果确认 |
| `Sources/CalendarApp/Decomposition/DecompositionActionEditor.swift` | 候选行动微调、选择、局部重拆和排序 |
| `Sources/CalendarApp/Decomposition/DecompositionScheduleEditor.swift` | 逐项日历选择、建议和手工日期时间微调 |
| `Sources/CalendarApp/Decomposition/AppleFoundationModelsDecompositionPlanner.swift` | macOS 26+ 真实设备端模型适配器 |
| `Sources/CalendarApp/Decomposition/LiveDecompositionPlanner.swift` | 运行时能力检查与诚实手动降级 |
| `Tests/.../Decomposition*Tests.swift` | 纯模型、原子写入、ViewModel、交互和生产装配门禁 |
| `docs/qa/2026-08-22-plan-and-schedule-product-run.md` | 最终打包 App 的真实实操证据与 `UNVERIFIED` 项 |

---

### Task 1: 让 Task Block 完成说明完整往返

**Files:**

- Modify: `Sources/WorkspaceDomain/BlockDocument.swift`
- Modify: `Sources/WorkspaceDomain/BlockDocumentValidator.swift`
- Modify: `Sources/WorkspaceDomain/WorkspaceChecksum.swift`
- Modify: `Sources/WorkspaceDomain/BlockMarkdownCodec.swift`
- Modify: `Sources/WorkspaceDomain/BlockHTMLCodec.swift`
- Modify: `Tests/WorkspaceDomainTests/BlockDocumentValidatorTests.swift`
- Modify: `Tests/WorkspaceDomainTests/BlockMarkdownCodecTests.swift`
- Modify: `Tests/WorkspaceDomainTests/BlockHTMLCodecTests.swift`
- Modify: `Tests/CalendarPersistenceTests/WorkspaceDocumentCodecTests.swift`
- Modify: `Tests/CalendarPersistenceTests/WorkspaceBackupServiceTests.swift`

**Interfaces:**

- Consumes: 现有 `TaskBlockState.completedAt`、`DocumentBlock.task(...)`、Workspace deterministic JSON codec。
- Produces: `TaskBlockState(completedAt:completionDescription:)` 和 `DocumentBlock.task(...completionDescription:)`；后续原子命令和 UI 只通过这两个入口构造完成说明。

```swift
public struct TaskBlockState: Codable, Equatable, Sendable {
    public var completedAt: Date?
    public var completionDescription: String?

    public init(completedAt: Date?, completionDescription: String? = nil) {
        self.completedAt = completedAt
        self.completionDescription = Self.canonicalCompletionDescription(completionDescription)
    }

    static func canonicalCompletionDescription(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
```

Jelly Markdown 的唯一 canonical 标记为任务行紧随的一行：

```text
- [ ] 给物业打电话
<!--jelly:task-completion:v1;b64=5ou/5Yiw5Y-v56Gu6K6k55qE5LiK6Zeo5pe26Ze0-->
```

payload 是 UTF-8 的标准 Base64；标记只有在紧接合法 Task 行、版本为 `v1`、Base64 可解码且规范化后非空时才消费。普通 Markdown、转义后的标记或失效标记不获得完成说明；失效的活动 Jelly 标记保留为正文并产生诊断。HTML 使用 `<li data-jelly-kind="task" data-jelly-completion-description="...">`，属性值按现有 HTML attribute 规则转义和解码。

- [ ] **Step 1: 写失败的领域和 JSON 往返测试**

```swift
@Test func taskCompletionDescriptionCanonicalizesAndOldJSONDefaultsToNil() throws {
    let task = try DocumentBlock.task(text: "联系物业", completionDescription: "  确认上门时间  \n")
    #expect(task.taskState?.completionDescription == "确认上门时间")

    let old = #"{"completedAt":null}"#.data(using: .utf8)!
    #expect(try JSONDecoder.workspaceDeterministic.decode(TaskBlockState.self, from: old)
        == TaskBlockState(completedAt: nil, completionDescription: nil))
}
```

- [ ] **Step 2: 运行测试并确认缺少新 initializer/字段而失败**

Run: `swift test --filter BlockDocumentValidatorTests`

Expected: FAIL，编译器报告 `completionDescription` 不存在；不是测试进程崩溃。

- [ ] **Step 3: 最小扩展 TaskBlockState 和 DocumentBlock.task**

```swift
public static func task(
    id: BlockID = BlockID(),
    text: String,
    indentLevel: Int = 0,
    completedAt: Date? = nil,
    completionDescription: String? = nil
) throws -> DocumentBlock
```

所有旧 call site 依赖默认值保持源码兼容。`BlockDocumentValidator.validateBlockLocal` 允许普通 Task 为 `nil`，但若值存在，必须已等于 canonical 值；非 Task 仍不允许 `taskState`。

- [ ] **Step 4: 运行领域测试确认通过**

Run: `swift test --filter BlockDocumentValidatorTests`

Expected: PASS。

- [ ] **Step 5: 写失败的 Markdown/HTML 精确往返测试**

```swift
@Test func jellyTaskCompletionMetadataRoundTripsWithoutChangingVisibleTitle() throws {
    let source = BlockDocument(blocks: [
        try .task(text: "给物业打电话", completionDescription: "拿到明确上门时间")
    ])
    let markdown = try BlockMarkdownCodec.exportMarkdown(source)
    #expect(markdown.contains("<!--jelly:task-completion:v1;b64="))
    let restored = try BlockMarkdownCodec.importMarkdown(
        markdown, idSource: .fixed(source.blocks.map(\.id)), checkedTaskCompletedAt: .distantPast
    )
    #expect(restored.document == source)
}
```

HTML 测试同时断言外部 `<li data-jelly-kind="task">` 无该属性时为 `nil`，恶意属性经过 escape/decode 后只得到原字符串，不执行标签。

- [ ] **Step 6: 实现 Markdown/HTML metadata 编解码**

Markdown 导入在成功解析 Task 后只向前看一行 metadata，并把 `nextIndex` 增加一；导出把标记纳入同一个 task chunk，保证连续列表的缩进上下文不被破坏。HTML parser 在打开 `li` 时读取完成说明属性，在 `finishCurrent()` 构造 `TaskBlockState`。

- [ ] **Step 7: 把完成说明纳入 Workspace checksum**

```swift
private struct NormalizedDocumentBlock: Codable {
    let completedAt: Date?
    let completionDescription: String?
    // existing fields remain unchanged
}
```

新增 checksum 测试：仅改变完成说明必须改变 `noteSnapshotChecksum`，保存再读、备份恢复后值完全一致。

- [ ] **Step 8: 运行 codec、持久化和备份 focused tests**

Run:

```bash
swift test --filter BlockMarkdownCodecTests
swift test --filter BlockHTMLCodecTests
swift test --filter WorkspaceDocumentCodecTests
swift test --filter WorkspaceBackupServiceTests
```

Expected: 全部 PASS。

- [ ] **Step 9: 提交本任务**

```bash
git add Sources/WorkspaceDomain/BlockDocument.swift Sources/WorkspaceDomain/BlockDocumentValidator.swift Sources/WorkspaceDomain/WorkspaceChecksum.swift Sources/WorkspaceDomain/BlockMarkdownCodec.swift Sources/WorkspaceDomain/BlockHTMLCodec.swift Tests/WorkspaceDomainTests Tests/CalendarPersistenceTests
git commit -m "feat(tasks): preserve completion descriptions"
```

---

### Task 2: 在连续编辑器中安静地显示完成说明

**Files:**

- Create: `Sources/CalendarApp/Notes/BlockEditor/TaskBlockCompletionDescriptionOverlay.swift`
- Modify: `Sources/CalendarApp/Notes/BlockEditor/BlockTextStyle.swift`
- Modify: `Sources/CalendarApp/Notes/BlockEditor/BlockDocumentTextProjection.swift`
- Modify: `Sources/CalendarApp/Notes/BlockEditor/BlockEditorSession.swift`
- Modify: `Sources/CalendarApp/Notes/BlockEditor/ContinuousBlockEditorHostView.swift`
- Modify: `Tests/CalendarAppTests/BlockDocumentTextProjectionTests.swift`
- Modify: `Tests/CalendarAppTests/ContinuousBlockEditorHostTests.swift`
- Modify: `Tests/CalendarAppTests/BlockEditorAccessibilityTests.swift`
- Create: `Tests/CalendarAppTests/TaskBlockCompletionDescriptionPresentationTests.swift`

**Interfaces:**

- Consumes: Task 1 的 `TaskBlockState.completionDescription`。
- Produces: `TaskBlockCompletionDescriptionOverlay.apply(document:textView:appearance:)`；完成说明不进入 `BlockDocumentTextProjection.contentRange`，所以标题编辑、复制和光标坐标保持原合同。连续投影根据当前 host 宽度为说明预留真实测量高度，overlay 使用同一测量函数，避免长中文覆盖下一 Block。

```swift
@MainActor
final class TaskBlockCompletionDescriptionOverlay: NSView {
    func apply(
        document: BlockDocument,
        textView: ContinuousBlockEditorTextView,
        appearance: CalendarSemanticAppearance,
        updateFramesImmediately: Bool = true
    )
    func updateFrames()
}

enum TaskCompletionDescriptionMetrics {
    static func measuredHeight(for text: String, width: CGFloat) -> CGFloat
}

extension BlockDocumentTextProjection {
    // Existing projection init gains the exact layout width owned by the text host.
    init(
        document: BlockDocument,
        appearance: CalendarSemanticAppearance,
        completionDescriptionWidth: CGFloat = NoteEditorLayout.maximumContentWidth - 32
    )
}
```

每个有说明的 Task 使用非可编辑、非命中测试的 `NSTextField(labelWithString:)`；字体 12 pt，颜色 `secondaryText`，从 Task 标题文字列左侧对齐。Task 标题段落预留说明实际测量高度加 6 pt 的段后空间；完成状态只降低标题和说明的整体透明度，不给说明加删除线。

- [ ] **Step 1: 写失败的投影坐标与展示测试**

```swift
@Test func completionDescriptionDoesNotEnterEditableProjection() throws {
    let block = try DocumentBlock.task(text: "给物业打电话", completionDescription: "拿到明确时间")
    let projection = BlockDocumentTextProjection(
        document: .init(blocks: [block]),
        appearance: CalendarTheme.light,
        completionDescriptionWidth: 320
    )
    #expect(projection.attributedString.string == "给物业打电话")
    let selection = BlockEditorSelection.text(
        anchor: .init(blockID: block.id, graphemeOffset: 0),
        focus: .init(blockID: block.id, graphemeOffset: "给物业打电话".count),
        preferredColumn: nil,
        typingAttributes: .init(marks: [], linkURL: nil)
    )
    #expect(try projection.nsRange(for: selection).length
        == ("给物业打电话" as NSString).length)
}
```

Hosted view 测试断言只有一个 editable `NSTextView`，说明 label 的 accessibility role 为 static text，且 label frame 在标题行下方、不覆盖下一个 Block。

- [ ] **Step 2: 运行测试确认 overlay 尚不存在而失败**

Run: `swift test --filter TaskBlockCompletionDescriptionPresentationTests`

Expected: FAIL，缺少 overlay 类型。

- [ ] **Step 3: 实现 overlay 和段落空间计算**

```swift
enum TaskCompletionDescriptionMetrics {
    static let font = NSFont.systemFont(ofSize: 12)
    static let topGap: CGFloat = 3
    static let bottomGap: CGFloat = 6
}
```

在 `ContinuousBlockEditorHostView` 中把说明 overlay 与 checkbox overlay 同级挂载；host 暴露 `completionDescriptionWidth`，值为 `bounds.width - BlockTextStyle.textColumnOffset(for: .task) - 10`。`BlockEditorSession.projectAuthoritativeState()` 把该值传给 projection，host 宽度变化超过 0.5 pt 时请求重新投影。`BlockTextStyle` 把 `measuredHeight + topGap + bottomGap` 加到该 Task 的 `paragraphSpacing`；`apply`、`layout`、宽度变化重投影、延迟高度维护四条路径都更新 frames。`hitTest` 永远返回 `nil`，鼠标点击仍交给正文 `NSTextView`。

- [ ] **Step 4: 增加空标题、长中文、深浅主题和完成态测试**

长说明用 360 pt 和 720 pt 两种宽度，断言自动换行后的 label 高度增长、下一个 Block 的首行 y 坐标随之下移；删除完成说明后预留空间归零。

- [ ] **Step 5: 运行编辑器 focused tests**

Run:

```bash
swift test --filter BlockDocumentTextProjectionTests
swift test --filter ContinuousBlockEditorHostTests
swift test --filter TaskBlockCompletionDescriptionPresentationTests
swift test --filter BlockEditorAccessibilityTests
```

Expected: 全部 PASS；现有光标和 IME 测试不回退。

- [ ] **Step 6: 提交本任务**

```bash
git add Sources/CalendarApp/Notes/BlockEditor Tests/CalendarAppTests
git commit -m "feat(editor): show task completion descriptions"
```

---

### Task 3: 建立临时拆解模型、来源快照和窄规划协议

**Files:**

- Create: `Sources/CalendarApp/Decomposition/DecompositionModels.swift`
- Create: `Sources/CalendarApp/Decomposition/DecompositionSourceCapture.swift`
- Create: `Sources/CalendarApp/Decomposition/DecompositionPlanning.swift`
- Create: `Tests/CalendarAppTests/DecompositionSourceCaptureTests.swift`
- Create: `Tests/CalendarAppTests/DecompositionDraftTests.swift`
- Create: `Tests/CalendarAppTests/DecompositionPlanningContractTests.swift`

**Interfaces:**

- Consumes: `Note`, `BlockDocument`,同 Block `BlockEditorSelection` 和 `WorkspaceChecksum.noteSnapshotChecksum`。
- Produces: 后续 ViewModel 与模型适配器共用的值类型和协议；任何协议输入都不含 `WorkspaceStore`。

```swift
struct DecompositionSourceSnapshot: Equatable, Sendable {
    struct TextRange: Equatable, Sendable {
        let blockID: BlockID
        let lowerGraphemeOffset: Int
        let upperGraphemeOffset: Int
    }
    let noteID: NoteID
    let noteRevision: Int64
    let workspaceRevision: Int64
    let sourceBlockID: BlockID?
    let selectedRange: TextRange?
    let normalizedText: String
    let noteChecksum: String
    let sourceChecksum: String
}

enum CandidateDuration: Int, CaseIterable, Equatable, Sendable {
    case minutes15 = 15, minutes30 = 30, minutes45 = 45
    case minutes60 = 60, minutes90 = 90
}

struct CalendarProposal: Equatable, Sendable {
    let schedule: CalendarSchedule
}

enum DecompositionStage: Int, CaseIterable, Equatable, Sendable {
    case understand, split, schedule
}

enum ManualDecompositionReason: Equatable, Sendable {
    case systemVersionUnsupported
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case localeUnsupported
    case timedOut
    case repeatedInvalidOutput
    case modelFailure
}

enum DecompositionMode: Equatable, Sendable {
    case intelligent
    case manual(reason: ManualDecompositionReason)
}

struct DecompositionQuestion: Equatable, Sendable {
    let text: String
    let quickAnswers: [String]
}

enum DecompositionRecoverableError: Equatable, Sendable {
    case requestCancelled
    case planningFailed
    case sourceChanged
    case calendarConflict
    case persistenceFailed
}

struct CandidateAction: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var completionDescription: String
    var estimatedDuration: CandidateDuration
    var selectedForCreation: Bool
    var selectedForCalendar: Bool
    var titleLockedByUser: Bool
    var completionLockedByUser: Bool
    var sourceCandidateID: UUID?
    var proposal: CalendarProposal?
}

enum ClarificationDecision: Equatable, Sendable {
    case ask(question: String, quickAnswers: [String])
    case notNeeded
}

struct PlannerCandidate: Equatable, Sendable {
    let existingID: UUID?
    let title: String
    let completionDescription: String
    let estimatedMinutes: Int
}

enum DecompositionPlannerAvailability: Equatable, Sendable {
    case available
    case unavailable(ManualDecompositionReason)
}

struct ClarificationRequest: Equatable, Sendable {
    let source: DecompositionSourceSnapshot
}

struct PlannerCandidateContext: Equatable, Sendable {
    let id: UUID
    let title: String
    let completionDescription: String
    let estimatedMinutes: Int
    let titleLockedByUser: Bool
    let completionLockedByUser: Bool
}

struct CandidateRequest: Equatable, Sendable {
    let source: DecompositionSourceSnapshot
    let answer: String?
    let existingCandidates: [PlannerCandidateContext]
    let validationFeedback: DecompositionOutputError?
}

struct SplitCandidateRequest: Equatable, Sendable {
    let source: DecompositionSourceSnapshot
    let answer: String?
    let target: PlannerCandidateContext
    let validationFeedback: DecompositionOutputError?
}

enum DecompositionOutputError: Error, Equatable, Sendable {
    case invalidCount(Int)
    case emptyTitle(index: Int)
    case emptyCompletion(index: Int)
    case invalidDuration(index: Int, minutes: Int)
    case duplicateExistingID(UUID)
    case unexpectedExistingIDs
}

protocol DecompositionPlanning: Sendable {
    var availability: DecompositionPlannerAvailability { get }
    func clarification(for request: ClarificationRequest) async throws -> ClarificationDecision
    func candidates(for request: CandidateRequest) async throws -> [PlannerCandidate]
    func splitCandidate(for request: SplitCandidateRequest) async throws -> [PlannerCandidate]
}

struct DecompositionDraft: Equatable, Sendable {
    var source: DecompositionSourceSnapshot
    var stage: DecompositionStage
    var question: DecompositionQuestion?
    var answer: String
    var candidates: [CandidateAction]
    var mode: DecompositionMode
    var lastRecoverableError: DecompositionRecoverableError?
}

enum DecompositionOutputValidator {
    static func validateInitial(_ output: [PlannerCandidate]) throws -> [PlannerCandidate]
    static func validateRefresh(
        _ output: [PlannerCandidate], expectedIDs: Set<UUID>
    ) throws -> [PlannerCandidate]
    static func validateSplit(_ output: [PlannerCandidate]) throws -> [PlannerCandidate]
}

enum DecompositionDraftReducer {
    static func mergeRefresh(
        _ output: [PlannerCandidate], into current: [CandidateAction]
    ) throws -> [CandidateAction]
    static func replaceCandidate(
        id: UUID, with output: [PlannerCandidate], in current: [CandidateAction]
    ) throws -> [CandidateAction]
}
```

`CandidateRequest` 包含来源、回答、当前候选摘要、锁定字段和可选 `validationFeedback`。初次请求的 `existingCandidates` 为空；刷新请求必须让输出 `existingID` 精确覆盖当前候选 ID 集合。`SplitCandidateRequest` 只包含目标候选、来源和回答；返回项的 `existingID` 必须为 `nil`。

- [ ] **Step 1: 写失败的来源捕获测试**

```swift
@Test func sameBlockSelectionUsesOnlySelectedTextAndAnchorsAfterThatBlock() throws {
    let blockID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000301")!)
    let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
    var note = Note.empty(id: NoteID(), categoryID: categoryID, now: .distantPast)
    note.document = .init(blocks: [
        .init(id: blockID, kind: .paragraph, inlineContent: .plain("预约牙医"),
              taskState: nil, indentLevel: 0)
    ])
    let selection = BlockEditorSelection.text(
        anchor: .init(blockID: blockID, graphemeOffset: 2),
        focus: .init(blockID: blockID, graphemeOffset: 4),
        preferredColumn: nil,
        typingAttributes: .init(marks: [], linkURL: nil)
    )
    let snapshot = try DecompositionSourceCapture.capture(
        note: note,
        workspaceRevision: 7,
        selection: selection
    )
    #expect(snapshot.sourceBlockID == blockID)
    #expect(snapshot.selectedRange?.lowerGraphemeOffset == 2)
    #expect(snapshot.normalizedText == "牙医")
}
```

同组测试覆盖：collapsed caret 回退整篇、全空白 Note、全空白选区、跨 Block text selection、block selection、emoji grapheme 边界和 note checksum。

- [ ] **Step 2: 运行来源测试确认类型缺失而失败**

Run: `swift test --filter DecompositionSourceCaptureTests`

Expected: FAIL，缺少 `DecompositionSourceCapture`。

- [ ] **Step 3: 实现快照捕获和 typed error**

```swift
enum DecompositionSourceCaptureError: Error, Equatable {
    case emptySource
    case crossBlockSelection
    case blockSelectionUnsupported
    case invalidSelection
}
```

collapsed text selection 视为“没有选区”，使用整篇纯文本和 `.end` 锚点；非 collapsed 选区必须 anchor/focus 在同一个 Block。整篇纯文本按 Block 顺序用 `\n` 连接，divider 贡献空字符串，最终只 trim 外层空白。`sourceChecksum` 对版本串、note checksum、可选 block/range 和 normalized text 做长度前缀编码后 SHA-256；测试断言任一组成变化都会改变 checksum。

- [ ] **Step 4: 写失败的候选校验和锁定合并测试**

```swift
@Test func refreshPreservesEachUserLockedFieldAndSelection() throws {
    let original = CandidateAction(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!,
        title: "我改的标题",
        completionDescription: "旧说明",
        estimatedDuration: .minutes30,
        selectedForCreation: false,
        selectedForCalendar: false,
        titleLockedByUser: true,
        completionLockedByUser: false,
        sourceCandidateID: nil,
        proposal: nil
    )
    let merged = try DecompositionDraftReducer.mergeRefresh(
        [PlannerCandidate(existingID: original.id, title: "模型标题",
                          completionDescription: "新说明", estimatedMinutes: 30)],
        into: [original]
    )
    #expect(merged[0].title == "我改的标题")
    #expect(merged[0].completionDescription == "新说明")
    #expect(merged[0].selectedForCreation == false)
}
```

再覆盖初始数量 1/6、空标题、空完成说明、重复 existing ID、非法时长、刷新 ID 集不一致、局部重拆只替换目标及其原位置。

- [ ] **Step 5: 实现值类型、输出 validator 和纯 Draft reducer**

`DecompositionOutputValidator.validateInitial` 强制 2～5；`validateRefresh` 强制 ID 集一致；`validateSplit` 强制 2～5 且 ID 全空。`DecompositionDraftReducer.replaceCandidate` 给新候选生成稳定 UUID，把 `sourceCandidateID` 设为被替换项 ID，并继承目标项的 creation/calendar 选择默认值。

- [ ] **Step 6: 增加 Scripted 测试适配器，但不加入 production factory**

```swift
actor ScriptedDecompositionPlanner: DecompositionPlanning {
    nonisolated let availability: DecompositionPlannerAvailability = .available
    enum Response {
        case clarification(ClarificationDecision)
        case candidates([PlannerCandidate])
        case failure(ScriptedPlannerFailure)
    }
    private var responses: [Response]
    // 每次调用 popFirst；无响应时抛 typed exhaustion error。
}

enum ScriptedPlannerFailure: Error, Equatable { case requestedFailure, exhausted }
```

它只放在 `Tests/CalendarAppTests/TestSupport.swift` 或 test target 文件，Release source 不得引用 `ScriptedDecompositionPlanner`。

- [ ] **Step 7: 运行临时模型与协议测试**

Run:

```bash
swift test --filter DecompositionSourceCaptureTests
swift test --filter DecompositionDraftTests
swift test --filter DecompositionPlanningContractTests
```

Expected: 全部 PASS。

- [ ] **Step 8: 提交本任务**

```bash
git add Sources/CalendarApp/Decomposition Tests/CalendarAppTests
git commit -m "feat(decomposition): add transient planning contracts"
```

---

### Task 4: 建立确定性的七日时间建议与共享冲突语义

**Files:**

- Create: `Sources/CalendarDomain/CalendarTimedOccupancy.swift`
- Create: `Sources/CalendarApp/Decomposition/CalendarProposalEngine.swift`
- Create: `Tests/CalendarDomainTests/CalendarTimedOccupancyTests.swift`
- Create: `Tests/CalendarAppTests/CalendarProposalEngineTests.swift`

**Interfaces:**

- Consumes: Task 3 的 `CandidateAction`、现有 `TimelineProjection`、`CalendarSchedule`、`CalendarDate` 和 `MinuteOfDay`。
- Produces: Task 5 reducer 与 Task 6 ViewModel 共用同一 timed overlap 判断；UI 收到按 candidate ID 映射的建议。

```swift
public enum CalendarTimedConflict: Equatable, Sendable {
    case item(UUID)
    case occurrence(OccurrenceKey)
    case proposed(UUID, UUID)
}

public enum CalendarTimedOccupancy {
    public static func overlaps(_ lhs: CalendarSchedule, _ rhs: CalendarSchedule) -> Bool
    public static func firstConflict(
        proposed: [CalendarItem],
        in state: CalendarState,
        range: CalendarDateRange
    ) -> CalendarTimedConflict?
}

enum CalendarProposalEngine {
    static func propose(
        for actions: [CandidateAction],
        calendarState: CalendarState,
        now: Date,
        timeZone: TimeZone
    ) -> [UUID: CalendarProposal]
}
```

精确算法：从今天到今天 `addingDays(6)`；每个自然日扫描 15 分钟网格；首日从 `max(09:00, ceil(now, 15 minutes))` 开始，其余日从 09:00 开始；结束不得晚于 21:00。只把有 start/end time 的 single item 和 recurrence occurrence 当成 clock occupation；untimed item 没有可证明的时段，不阻塞建议。多项行动按当前顺序依次占位，后项同时避让既有事项和本轮前项。

- [ ] **Step 1: 写失败的半开区间冲突测试**

```swift
@Test func touchingTimedRangesDoNotOverlap() throws {
    let first = try schedule(day: day, start: (9, 0), end: (9, 30))
    let second = try schedule(day: day, start: (9, 30), end: (10, 0))
    #expect(CalendarTimedOccupancy.overlaps(first, second) == false)
}
```

覆盖同日包含、跨日、untimed、recurrence occurrence 和 proposed items 自相冲突。

- [ ] **Step 2: 运行 CalendarDomain 测试确认类型缺失而失败**

Run: `swift test --filter CalendarTimedOccupancyTests`

Expected: FAIL。

- [ ] **Step 3: 实现共享 overlap，使用 `[start, end)` 语义**

不得用 `Date()` 比较本地日程；先按 `CalendarDate` 判断日交集，再比较 `MinuteOfDay.value`。`firstConflict` 用 `TimelineProjection.make(... hiddenCategoryIDs: [])` 展开 recurrence。

- [ ] **Step 4: 写失败的排期引擎测试**

```swift
@Test func proposalUsesEarliestNonOverlappingSlotsInCandidateOrder() throws {
    let proposals = CalendarProposalEngine.propose(
        for: [candidate(30), candidate(45)],
        calendarState: stateWithTimedItem(9, 0, 9, 30),
        now: localInstant(day, 8, 0),
        timeZone: shanghai
    )
    #expect(proposals[firstID]?.schedule.startTime == MinuteOfDay(hour: 9, minute: 30))
    #expect(proposals[secondID]?.schedule.startTime == MinuteOfDay(hour: 10, minute: 0))
}
```

覆盖 20:30 的 90 分钟溢出、七天均满返回无建议、首日过去时间、上海与洛杉矶时区、夏令时切换日、untimed item 不阻塞和 recurrence 阻塞。

- [ ] **Step 5: 实现 proposal engine**

只为 `selectedForCreation && selectedForCalendar` 的行动生成建议；其他 ID 不出现在结果字典。候选 7 天都无位置时，该 ID 无值，UI 显示“暂无建议”，不得自动创建 untimed Calendar Item。

- [ ] **Step 6: 运行 focused tests**

Run:

```bash
swift test --filter CalendarTimedOccupancyTests
swift test --filter CalendarProposalEngineTests
```

Expected: 全部 PASS。

- [ ] **Step 7: 提交本任务**

```bash
git add Sources/CalendarDomain/CalendarTimedOccupancy.swift Sources/CalendarApp/Decomposition/CalendarProposalEngine.swift Tests/CalendarDomainTests/CalendarTimedOccupancyTests.swift Tests/CalendarAppTests/CalendarProposalEngineTests.swift
git commit -m "feat(calendar): propose honest available time slots"
```

---

### Task 5: 用一个 Workspace 命令原子写入并精确撤销

**Files:**

- Create: `Sources/WorkspaceDomain/DecompositionWorkspaceCommand.swift`
- Create: `Sources/WorkspaceDomain/WorkspaceReducer+Decomposition.swift`
- Modify: `Sources/WorkspaceDomain/WorkspaceCommand.swift`
- Modify: `Sources/WorkspaceDomain/WorkspaceReducer.swift`
- Create: `Tests/WorkspaceDomainTests/DecompositionWorkspaceCommandTests.swift`
- Create: `Tests/CalendarAppTests/DecompositionWorkspaceStoreTests.swift`

**Interfaces:**

- Consumes: Task 1 的完成说明、Task 4 的 `CalendarTimedOccupancy`、现有 Workspace reducer/revision/store undo。
- Produces: Task 6 最终提交唯一可调用的 `.applyDecompositionPlan(payload)`。

```swift
public enum DecompositionInsertionAnchor: Equatable, Sendable {
    case after(BlockID)
    case end
}

public struct ApplyDecompositionPlanPayload: Equatable, Sendable {
    public let noteID: NoteID
    public let expectedNoteRevision: Int64
    public let expectedWorkspaceRevision: Int64
    public let insertionAnchor: DecompositionInsertionAnchor
    public let taskBlocks: [DocumentBlock]
    public let calendarItems: [CalendarItem]
    public let links: [TaskBlockCalendarLink]
}

public enum DecompositionWorkspaceConflict: Equatable, Sendable {
    case noteMissing
    case noteChanged(currentRevision: Int64)
    case anchorMissing(BlockID)
    case calendarChanged(CalendarTimedConflict)
}
```

`WorkspaceConflict` 新增 `.decomposition(DecompositionWorkspaceConflict)`；结构伪造继续抛 `WorkspaceReducerError.invalidDecompositionPlan`，因为它是编程错误而不是用户可恢复并发。`expectedWorkspaceRevision` 不是“一有无关写入就失败”：revision 不同会触发完整的当前日历重检，只有实际时间冲突才返回 `calendarChanged`，避免普通用户因为无关修改重复操作。

- [ ] **Step 1: 写失败的成功路径 reducer 测试**

```swift
@Test func applyPlanInsertsOrderedTasksItemsAndLinksInOneRevision() throws {
    let result = try WorkspaceReducer.reduce(
        workspace,
        command: .applyDecompositionPlan(validPayload(after: sourceBlockID)),
        now: instant
    )
    let changed = try #require(result.change)
    #expect(changed.state.revision == workspace.revision + 1)
    #expect(changed.state.notes[noteID]?.revision == note.revision + 1)
    #expect(insertedTitles(changed.state) == ["打电话", "记录时间"])
    #expect(changed.state.calendar.items.count == workspace.calendar.items.count + 1)
    #expect(changed.state.taskBlockLinks.count == workspace.taskBlockLinks.count + 1)
}
```

- [ ] **Step 2: 写失败的全有或全无矩阵测试**

逐项覆盖：note missing、note revision stale、anchor missing、空 task 数组、非 task block、空标题、空完成说明、重复 block ID、已有 block ID、重复/已有 calendar ID、link 数量或端点不匹配、item 标题不等于 task 标题、completion 不一致、未知 category、item 时间冲突、recurrence occurrence 冲突和新 items 互相冲突。每个 case 都断言输入 `workspace` 完全不变。

- [ ] **Step 3: 运行 reducer 测试确认 command 缺失而失败**

Run: `swift test --filter DecompositionWorkspaceCommandTests`

Expected: FAIL，缺少 command/payload。

- [ ] **Step 4: 实现 payload、typed conflict 和 reducer 路由**

```swift
case let .applyDecompositionPlan(payload):
    return try applyDecompositionPlan(payload, in: &candidate, now: now, metadata: &metadata)
```

实现顺序固定为：验证全部输入 → 在局部 `candidate` Note 中插入 blocks → 逐项调用现有 `applyCalendar(.createItem...)` → 建 baseline primary note relation → 插入 links → 交回普通 final validator/revision allocator。任何 throw/conflict 发生在发布 reduction 前。

- [ ] **Step 5: 明确插入和关系规则**

`.after(id)` 找 exact block index 并在 `index + 1` 连续插入；`.end` 直接 append。每个 Task 必须 `taskState?.completionDescription != nil`。Calendar Item 只允许 non-recurring `.task`、同 Note category、标题为规范化 Task 标题、completedAt 等于 block。每个 item 必须恰好一个 link，且 baseline primaryNoteID 等于来源 Note。

- [ ] **Step 6: 写失败的 Store 撤销与并发测试**

```swift
@Test func oneUndoRemovesOnlyObjectsCreatedByPlan() async throws {
    let outcome = try await store.sendWorkspace(
        .applyDecompositionPlan(payload), undoLabel: "拆开并安排"
    )
    guard case .committed = outcome else {
        Issue.record("plan must commit before undo is exercised")
        return
    }
    _ = try await store.sendCalendar(.createItem(unrelated), undoLabel: "无关事项")
    _ = try await store.undo()
    #expect(store.calendarState.items[unrelated.id] == nil)
    _ = try await store.undo()
    #expect(planObjectsAreAbsent(store.state))
    #expect(originalObjectsAreUnchanged(store.state))
}
```

再覆盖 plan commit 后出现无关 Note 修改时，精确 reverse record 不回滚那次修改；持久化失败返回非 committed outcome，内存不发布半成品。

- [ ] **Step 7: 运行 reducer/store focused tests**

Run:

```bash
swift test --filter DecompositionWorkspaceCommandTests
swift test --filter DecompositionWorkspaceStoreTests
swift test --filter WorkspaceStoreTests
```

Expected: 全部 PASS。

- [ ] **Step 8: 提交本任务**

```bash
git add Sources/WorkspaceDomain/DecompositionWorkspaceCommand.swift Sources/WorkspaceDomain/WorkspaceReducer+Decomposition.swift Sources/WorkspaceDomain/WorkspaceCommand.swift Sources/WorkspaceDomain/WorkspaceReducer.swift Tests/WorkspaceDomainTests/DecompositionWorkspaceCommandTests.swift Tests/CalendarAppTests/DecompositionWorkspaceStoreTests.swift
git commit -m "feat(workspace): apply decomposition plans atomically"
```

---

### Task 6: 编排请求、微调、手动降级和最终提交

**Files:**

- Create: `Sources/CalendarApp/Decomposition/DecompositionWorkbenchModel.swift`
- Create: `Sources/CalendarApp/Decomposition/DecompositionPlanBuilder.swift`
- Create: `Tests/CalendarAppTests/DecompositionWorkbenchModelTests.swift`
- Create: `Tests/CalendarAppTests/DecompositionPlanBuilderTests.swift`

**Interfaces:**

- Consumes: Task 3 的临时模型/协议、Task 4 的 proposal engine、Task 5 的原子 command 和现有 `WorkspaceStore`。
- Produces: Task 7 的唯一 UI 状态与动作入口；View 不自行调模型、不拼 payload、不直接写 Store。

```swift
struct DecompositionPlanIDs: Equatable, Sendable {
    let blockIDs: [BlockID]
    let calendarItemIDs: [UUID]
}

enum DecompositionPlanBuilder {
    static func makePayload(
        snapshot: DecompositionSourceSnapshot,
        candidates: [CandidateAction],
        note: Note,
        workspaceRevision: Int64,
        now: Date,
        ids: DecompositionPlanIDs
    ) throws -> ApplyDecompositionPlanPayload
}

enum DecompositionOperation: Equatable, Sendable {
    case clarification
    case generateCandidates
    case refreshCandidates
    case splitCandidate(UUID)
}

enum DecompositionRequestState: Equatable, Sendable {
    case idle
    case running(id: UUID, operation: DecompositionOperation)
}

protocol DecompositionSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousClockDecompositionSleeper: DecompositionSleeping {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

@MainActor
@Observable final class DecompositionWorkbenchModel {
    private(set) var draft: DecompositionDraft
    private(set) var requestState: DecompositionRequestState = .idle
    private(set) var isCommitting = false
    private var activeRequest: Task<Void, Never>?

    init(
        snapshot: DecompositionSourceSnapshot,
        planner: any DecompositionPlanning,
        store: WorkspaceStore,
        clock: @escaping @Sendable () -> Date = Date.init,
        timeZone: TimeZone = .autoupdatingCurrent,
        sleeper: any DecompositionSleeping = ContinuousClockDecompositionSleeper(),
        uuid: @escaping @Sendable () -> UUID = UUID.init,
        requestTimeout: Duration = .seconds(20)
    )

    func start() async
    func submitAnswer(_ answer: String) async
    func refreshUnlockedCandidates() async
    func split(_ candidateID: UUID) async
    func cancelRequest()
    func enterManualMode(reason: ManualDecompositionReason)
    func addManualCandidate()
    func deleteCandidate(id: UUID)
    func moveCandidate(fromOffsets: IndexSet, toOffset: Int)
    func updateTitle(id: UUID, value: String)
    func updateCompletion(id: UUID, value: String)
    func setSelectedForCreation(id: UUID, selected: Bool)
    func setSelectedForCalendar(id: UUID, selected: Bool)
    func setProposal(id: UUID, proposal: CalendarProposal?)
    func advanceToSchedule()
    func refreshCalendarProposals()
    func commit() async -> DecompositionCommitResult
}
```

`DecompositionPlanBuilder.makePayload` 是纯函数：只取 `selectedForCreation` 的候选，按当前顺序生成 Task Blocks；只对其中 `selectedForCalendar && proposal != nil` 的候选生成 Calendar Item 与 link。所有 ID、`createdAt` 和 `updatedAt` 在按最终按钮之后一次生成，不在候选阶段提前占用。

- [ ] **Step 1: 写失败的主状态机测试**

```swift
@Test func startAsksAtMostOneQuestionThenGeneratesCandidates() async throws {
    let planner = ScriptedDecompositionPlanner([
        .clarification(.ask(question: "完成后最重要的结果是什么？", quickAnswers: ["拿到确认"])),
        .candidates(validSuggestions(count: 3))
    ])
    let model = makeModel(planner: planner)
    await model.start()
    #expect(model.draft.stage == .understand)
    #expect(model.draft.question?.text == "完成后最重要的结果是什么？")
    await model.submitAnswer("拿到确认")
    #expect(model.draft.stage == .split)
    #expect(model.draft.candidates.count == 3)
}
```

另写无需追问直接进入 `.split`、空 answer 不能提交、返回前一步不丢候选、进入 `.schedule` 只冻结临时草稿而不写 Store 的测试。

- [ ] **Step 2: 运行 ViewModel 测试确认类型缺失而失败**

Run: `swift test --filter DecompositionWorkbenchModelTests`

Expected: FAIL。

- [ ] **Step 3: 实现单活动请求、取消和迟到结果丢弃**

```swift
private func beginRequest(_ operation: DecompositionOperation) -> UUID {
    activeRequest?.cancel()
    let id = UUID()
    requestState = .running(id: id, operation: operation)
    return id
}

private func accepts(_ requestID: UUID) -> Bool {
    guard case let .running(currentID, _) = requestState else { return false }
    return currentID == requestID && !Task.isCancelled
}
```

`DecompositionSleeping.sleep(for:)` 由 production 的 `ContinuousClock` 实现，测试用 controllable sleeper 跨过 20 秒边界而不真实等待。每个 async 结果在写 draft 前检查 request ID；`cancelRequest()` 取消 Task 并回到 `.idle`，保留 question、answer 和候选。

- [ ] **Step 4: 写失败的并发、超时和修复上限测试**

测试使用 controllable continuation：请求 A 悬挂，启动 B 后再返回 A，断言 A 完全不改变 draft；取消不清空用户字段；20 秒边界用注入 clock/sleeper，不做真实等待；第一次 invalid 会带 `validationFeedback` 精确重试一次，第二次 invalid 后只切手动模式，planner 总调用次数为 2。

- [ ] **Step 5: 实现 bounded request runner 和诚实降级**

```swift
enum DecompositionPlanningFailure: Error, Equatable {
    case unavailable(ManualDecompositionReason)
    case timedOut
    case cancelled
    case invalidOutput(DecompositionOutputError)
    case modelFailure
}
```

availability 在每次模型请求前重检。`CancellationError` 不显示失败；timeout、unavailable、语言不支持和两次 invalid 映射为明确手动 reason。用户已改字段、手工新增项和 answer 都不得被切换动作清空。

- [ ] **Step 6: 实现所有微调动作和局部重拆**

`updateTitle`/`updateCompletion` 先规范化 UI 输入但允许编辑中的暂时空串，离开字段或进入下一阶段时才阻止空值；每次用户编辑只锁定对应字段。`split(id)` 成功后调用 Task 3 的纯 replacement；失败时保留目标原项。排序、勾选、删除和手工新增都是同步临时动作，不发模型请求。

- [ ] **Step 7: 写失败的 payload builder 测试**

```swift
@Test func builderCreatesAllSelectedTasksButOnlyScheduledItems() throws {
    let payload = try DecompositionPlanBuilder.makePayload(
        snapshot: snapshot,
        candidates: [selectedScheduled, selectedUnscheduled, deselected],
        note: note,
        workspaceRevision: 9,
        now: instant,
        ids: fixedPlanIDs
    )
    #expect(payload.taskBlocks.count == 2)
    #expect(payload.calendarItems.count == 1)
    #expect(payload.links.count == 1)
    #expect(payload.calendarItems[0].title
        == payload.taskBlocks[0].inlineContent.spans.map(\.text).joined())
}
```

覆盖选区 `.after(blockID)`、整篇 `.end`、空 creation selection 禁止提交、缺 proposal 的 calendar selection 禁止提交或要求用户取消安排、完成说明写入 taskState 且不进 Calendar title。

- [ ] **Step 8: 实现 commit outcome 映射**

```swift
enum DecompositionCommitResult: Equatable {
    case committed(createdActions: Int, scheduledActions: Int, stateGeneration: UInt)
    case sourceChanged
    case calendarConflict
    case notCommitted(message: String)
}
```

`.committed` 才关闭工作台；source conflict 保留草稿并回 `.split`，calendar conflict 保留草稿并回 `.schedule`；persistence blocked/not committed 显示“原笔记和日历没有被改动，可稍后重试”。

- [ ] **Step 9: 运行 ViewModel、builder、Store focused tests**

Run:

```bash
swift test --filter DecompositionWorkbenchModelTests
swift test --filter DecompositionPlanBuilderTests
swift test --filter DecompositionWorkspaceStoreTests
```

Expected: 全部 PASS。

- [ ] **Step 10: 提交本任务**

```bash
git add Sources/CalendarApp/Decomposition/DecompositionWorkbenchModel.swift Sources/CalendarApp/Decomposition/DecompositionPlanBuilder.swift Tests/CalendarAppTests/DecompositionWorkbenchModelTests.swift Tests/CalendarAppTests/DecompositionPlanBuilderTests.swift
git commit -m "feat(decomposition): orchestrate editable planning sessions"
```

---

### Task 7: 做出可用键盘微调的三阶段工作台并接入 Notes

**Files:**

- Create: `Sources/CalendarApp/Decomposition/DecompositionWorkbenchView.swift`
- Create: `Sources/CalendarApp/Decomposition/DecompositionConversationPane.swift`
- Create: `Sources/CalendarApp/Decomposition/DecompositionActionEditor.swift`
- Create: `Sources/CalendarApp/Decomposition/DecompositionScheduleEditor.swift`
- Modify: `Sources/CalendarApp/Notes/NoteEditorView.swift`
- Modify: `Sources/CalendarApp/Notes/NotesSplitView.swift`
- Modify: `Sources/CalendarApp/DesignSystem/CalendarTheme.swift`
- Create: `Tests/CalendarAppTests/DecompositionWorkbenchPresentationTests.swift`
- Create: `Tests/CalendarAppTests/DecompositionWorkbenchInteractionTests.swift`
- Modify: `Tests/CalendarAppTests/NotesVerticalIntegrationTests.swift`
- Modify: `Tests/CalendarAppTests/BlockEditorAccessibilityTests.swift`

**Interfaces:**

- Consumes: Task 6 `DecompositionWorkbenchModel` 和 `NoteEditorView` 现有 autosave/native-input finalizer。
- Produces: 用户可从真实选区或整篇 Note 打开的 centered sheet；成功后重建当前 autosave/editor session、在 Note 前景显示结果和一次性撤销。

```swift
struct DecompositionWorkbenchView: View {
    @Bindable var model: DecompositionWorkbenchModel
    let onCancel: () -> Void
    let onCommitted: (DecompositionCommitResult) -> Void
}

private struct DecompositionRequest: Identifiable {
    let id = UUID()
    let snapshot: DecompositionSourceSnapshot
}
```

工作台宽布局目标 `960 × 680`，最小 `720 × 560`。左区约 34%，背景使用由当前 theme 派生的暖灰 `conversationSurface`；右区约 66%，使用 `elevatedSurface`；底部 64 pt 结果区跨全宽，和内容以 separator 分开。主字号只能是 16/15/14/12 pt。`ViewThatFits(in: .horizontal)` 在内容宽度小于 760 pt 时换成上下分区，不做两列硬挤压。

- [ ] **Step 1: 写失败的入口和草稿保护测试**

```swift
@Test func entryFinalizesNativeInputFlushesLatestAndCapturesPersistedRevision() async throws {
    let host = productionNoteEditorHost(note: note, store: store)
    host.session.setSelection(sameBlockSelection)
    host.nativeTextView.setMarkedText("牙", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: 0, length: 0))
    host.tapAccessibilityButton("拆开并安排")
    #expect(await waitUntil { host.presentedWorkbenchSnapshot != nil })
    #expect(host.presentedWorkbenchSnapshot?.noteRevision == store.state.notes[note.id]?.revision)
}
```

另覆盖 empty source、cross-block selection、protected-only/unsafe flush：工作台不出现，编辑焦点保留，顶部提示具体下一步。

- [ ] **Step 2: 运行 integration 测试确认入口缺失而失败**

Run: `swift test --filter NotesVerticalIntegrationTests`

Expected: FAIL，找不到“拆开并安排”入口。

- [ ] **Step 3: 在 NoteEditorView 接入入口和 centered sheet**

入口放在分类/安排工具条中，文案固定为“拆开并安排”；只有用户主动点击才捕获来源。先调用现有 `autosave.flushLatest(finalizer:)`，再用 Store 中的持久 Note 和 editor 当前 selection 构造 snapshot。sheet dismiss 时调用 model `cancelRequest()`，不保存临时 draft。

- [ ] **Step 4: 写失败的三阶段视觉/辅助功能合同测试**

```swift
@Test func workbenchExposesThreeRegionsAndResultSummaryToAccessibility() throws {
    let host = NSHostingView(rootView: fixtureWorkbench(stage: .split))
    let labels = accessibilityLabels(in: host)
    #expect(labels.contains("理解"))
    #expect(labels.contains("拆开"))
    #expect(labels.contains("安排"))
    #expect(labels.contains("行动草稿"))
    #expect(labels.contains("创建 3 个行动，并安排其中 2 个"))
}
```

同组测试检查 light/dark semantic colors、reduceMotion 无插值、宽/窄 layout choice、长中文换行和 loading cancel button 的名称。

- [ ] **Step 5: 实现工作台壳和理解区**

顶部 segmented navigation 只能回到已到达阶段；左区显示来源摘要、一个 question、answer field 和不超过 3 个 quick answers。模型运行时文案只写“正在整理…”并显示“停止”；不用拟人语气或进度百分比。manual mode 顶部说明“当前设备暂时不能使用智能拆解，你仍可手动添加和安排行动”。

- [ ] **Step 6: 实现高控制感 Action editor**

每行默认直接显示 creation checkbox、14 pt 标题、12 pt 完成说明、时长和“继续拆开”。选中行才展开两个 text fields、时长 picker、上移/下移和更多菜单；删除在更多菜单，新增手工行动固定在列表底部。拖放排序和上/下按钮共用 `moveCandidate`，确保键盘与 VoiceOver 不依赖拖拽。

- [ ] **Step 7: 实现 Schedule editor 和清楚的最终按钮**

每个选中 creation 的行动都有“加入日历”开关；打开后显示 proposal 或“暂无建议”，并允许 DatePicker + start time + duration 手工设置。最后按钮按实时数量只可能是：

```swift
created == 0 ? "至少保留一个行动"
scheduled == 0 ? "创建 \(created) 个行动，暂不安排"
               : "创建 \(created) 个行动，并安排其中 \(scheduled) 个"
```

提交中禁用所有 mutating controls，保留可读摘要；不得出现会触发第二次 command 的双击窗口。

- [ ] **Step 8: 写失败的完整键盘旅程测试**

Hosted AppKit 测试通过真实 key equivalent 覆盖：打开 → 输入 answer → Return → Tab 到第一个标题 → 编辑并锁定 → 下移 → 局部重拆 → 切 schedule → 关闭一个 calendar selection → Return 最终确认。断言焦点在模型结果到达后仍属于原编辑 field，Escape 取消请求/关闭 sheet 时都不写 Store。

- [ ] **Step 9: 处理成功反馈、autosave rebase 和一次性撤销**

成功后关闭 sheet，使用 Store 中新 Note 重新 `autosave.beginSession`，让新 Task Blocks 立即出现在同一编辑器；顶部反馈为“已创建 N 个行动，并安排其中 M 个”。撤销按钮只在 `statePublicationGeneration` 仍等于成功结果时启用，调用一次 `store.undo()`；有后续写入时隐藏，避免撤错。

- [ ] **Step 10: 运行 UI、交互和 Notes 回归**

Run:

```bash
swift test --filter DecompositionWorkbenchPresentationTests
swift test --filter DecompositionWorkbenchInteractionTests
swift test --filter NotesVerticalIntegrationTests
swift test --filter BlockEditorAccessibilityTests
swift test --filter TaskBlockCalendarIntegrationTests
```

Expected: 全部 PASS。

- [ ] **Step 11: 提交本任务**

```bash
git add Sources/CalendarApp/Decomposition Sources/CalendarApp/Notes/NoteEditorView.swift Sources/CalendarApp/Notes/NotesSplitView.swift Sources/CalendarApp/DesignSystem/CalendarTheme.swift Tests/CalendarAppTests
git commit -m "feat(notes): add plan and schedule workbench"
```

---

### Task 8: 接入真实 Apple Foundation Models，并保证旧系统诚实可用

**Files:**

- Create: `Sources/CalendarApp/Decomposition/AppleFoundationModelsDecompositionPlanner.swift`
- Create: `Sources/CalendarApp/Decomposition/LiveDecompositionPlanner.swift`
- Modify: `Sources/CalendarApp/AppEnvironment.swift`
- Modify: `Sources/CalendarApp/AppShell/AppShellView.swift`
- Modify: `Sources/CalendarApp/Notes/NotesSplitView.swift`
- Create: `Tests/CalendarAppTests/LiveDecompositionPlannerTests.swift`
- Create: `Tests/CalendarAppTests/AppleFoundationModelsPromptContractTests.swift`
- Modify: `Tests/CalendarAppTests/AppEnvironmentWorkspaceCutoverTests.swift`

**Interfaces:**

- Consumes: Task 3 的 `DecompositionPlanning`；Task 6 已拥有 timeout、repair 和 cancellation policy。
- Produces: macOS 26+、设备/Apple Intelligence/locale 可用时的真实 on-device adapter；其他环境返回 typed unavailable，工作台走手动模式。

```swift
enum LiveDecompositionPlanner {
    static func make(locale: Locale = .autoupdatingCurrent) -> any DecompositionPlanning
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
final class AppleFoundationModelsDecompositionPlanner: DecompositionPlanning, @unchecked Sendable {
    private let model: SystemLanguageModel
    private let locale: Locale
}
#endif
```

`@unchecked Sendable` 只有在 adapter 不共享可变 `LanguageModelSession` 时允许：每次 public request 创建独立 session，取消由调用 Task 传播。若实现选择复用 session，则改为 actor，不得保留 unchecked。

- [ ] **Step 1: 写失败的 runtime factory 门禁测试**

测试可注入一个 `SystemModelCapabilityChecking` seam，覆盖 macOS 不足、deviceNotEligible、appleIntelligenceNotEnabled、modelNotReady、locale unsupported 和 available。每个 unavailable reason 映射到可理解的 `ManualDecompositionReason`；`.production` 环境返回的 dynamic type 名称不得包含 `Scripted`、`Mock` 或 `Fixture`。

- [ ] **Step 2: 运行 factory 测试确认 live planner 缺失而失败**

Run: `swift test --filter LiveDecompositionPlannerTests`

Expected: FAIL。

- [ ] **Step 3: 实现条件编译、availability 和 locale 检查**

```swift
static func make(locale: Locale) -> any DecompositionPlanning {
#if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        return AppleFoundationModelsDecompositionPlanner(locale: locale)
    }
#endif
    return UnavailableDecompositionPlanner(reason: .systemVersionUnsupported)
}
```

adapter 的 `availability` 每次读取 `SystemLanguageModel.default.availability` 并调用 `supportsLocale(locale)`。不要缓存“available”，因为系统模型下载/设置可在 App 运行期间变化。

- [ ] **Step 4: 写失败的 prompt 与结构化输出合同测试**

把 prompt 组装放在无 framework 依赖的 `DecompositionPromptBuilder`，测试逐字包含以下约束：只问一个关键问题或明确无需追问；初始 2～5；行动可独立完成；完成说明可观察；不得把父意图安排；只返回给定时长；不得覆盖标记为 locked 的字段；局部重拆不谈其他候选；中文输入用中文回答。

- [ ] **Step 5: 用 `@Generable` 响应类型实现三种调用**

```swift
@available(macOS 26.0, *)
@Generable
private struct GeneratedActionList {
    @Guide(description: "2 到 5 个按执行顺序排列的独立行动")
    let actions: [GeneratedAction]
}

@available(macOS 26.0, *)
@Generable
private struct GeneratedAction {
    let existingID: String?
    let title: String
    let completionDescription: String
    @Guide(description: "只能是 15、30、45、60 或 90")
    let estimatedMinutes: Int
}
```

通过 `LanguageModelSession(model:instructions:)` 和 `respond(to:generating:)` 获取 `response.content`。生成类型只负责语法形状，所有数量、UUID、空白、时长和锁定规则仍交给 Task 3 validator；不要把 `@Guide` 当安全校验。

- [ ] **Step 6: 把 planner 从 AppEnvironment 单点注入**

```swift
@MainActor
struct AppEnvironment {
    let store: WorkspaceStore
    let decompositionPlanner: any DecompositionPlanning
    // existing properties
}
```

`AppEnvironment.live` 只能调用 `LiveDecompositionPlanner.make()`；`AppShellView` → `NotesSplitView` → `NoteEditorView` 逐层显式传递同一个 planner。Preview/tests 可注入 scripted planner，但 production source 不以环境变量切换到假模型。

- [ ] **Step 7: 增加真实 framework 编译 characterization**

在当前 SDK 上执行：

```bash
swift build -c debug --product PersonalCalendar
swift build -c release --product PersonalCalendar
```

Expected: macOS 14 deployment target 仍可链接；所有 FoundationModels 符号都被 `#if canImport` 和 `@available(macOS 26.0, *)` 保护。若当前测试机不满足真实 model availability，只记录 adapter 编译与 unavailable 映射通过，真实中文质量仍标 `UNVERIFIED`。

- [ ] **Step 8: 运行装配、prompt 和全 App focused tests**

Run:

```bash
swift test --filter LiveDecompositionPlannerTests
swift test --filter AppleFoundationModelsPromptContractTests
swift test --filter AppEnvironmentWorkspaceCutoverTests
swift test --filter DecompositionWorkbenchModelTests
```

Expected: 全部 PASS。

- [ ] **Step 9: 提交本任务**

```bash
git add Sources/CalendarApp/Decomposition Sources/CalendarApp/AppEnvironment.swift Sources/CalendarApp/AppShell/AppShellView.swift Sources/CalendarApp/Notes/NotesSplitView.swift Tests/CalendarAppTests
git commit -m "feat(ai): use Apple on-device decomposition planner"
```

---

### Task 9: 累计 review、工程门禁、最终包实操和 9 分候选验收

**Files:**

- Create: `Tests/CalendarAppTests/DecompositionEndToEndTests.swift`
- Create: `docs/qa/2026-08-22-plan-and-schedule-product-run.md`
- Modify only when a discovered defect has a failing regression: files owned by Tasks 1～8。

**Interfaces:**

- Consumes: Tasks 1～8 的完整纵向闭环和 `Scripts/build-app.sh` 最终产物。
- Produces: 可复核的工程证据、真实 App 实操记录、真实模型质量记录或明确 `UNVERIFIED`、以及交给用户本人的两条验收旅程。

- [ ] **Step 1: 写并跑生产路径端到端回归**

```swift
@Test func jsonStorePersistsPlanAcrossRestartAndSameSessionUndoRemovesOnlyPlanObjects() async throws {
    let urls = temporaryWorkspaceURLs()
    let firstStore = try await loadJSONStore(urls)
    let source = try await createChineseSourceNote(in: firstStore)
    let payload = try makeRealPayload(source: source, calendarState: firstStore.calendarState)
    _ = try await firstStore.sendWorkspace(.applyDecompositionPlan(payload), undoLabel: "拆开并安排")

    let restarted = try await loadJSONStore(urls)
    #expect(planObjectsExist(restarted.state))

    _ = try await firstStore.undo()
    let afterUndo = try await loadJSONStore(urls)
    #expect(planObjectsAreAbsent(afterUndo.state))
    #expect(sourceNoteAndPreexistingObjectsRemain(afterUndo.state))
}
```

此测试必须使用真实 `JSONWorkspaceRepository`、真实 deterministic scheduler 和 production reducer；不得用 in-memory repository 替代。WorkspaceStore 的 undo stack 是会话内存态，不做持久化撤销系统，因此重启后的新 Store 不能 `undo()`。两个独立保证是：1. 重启后的新 Store 从同一 JSON 文件 load，确认 task blocks、completionDescription、calendar items、relations、links 全部存在；2. 原 firstStore 在同一会话 undo 一次后，第三个 fresh store 再 load，确认只移除本轮 plan 对象，来源 Note 和既有对象仍在。模型可用 scripted adapter 只负责给出确定候选，不能替代后续产品实操的真实模型。

- [ ] **Step 2: Grok 每完成一个任务，Codex 做累计独立 code review**

Grok 每完成一个任务，Codex 都逐提交检查：协议边界是否泄露 Store、候选是否持久化、原文是否可能改写、用户锁是否可能被覆盖、late result 是否越权、FoundationModels 是否破坏 macOS 14、原子 reducer 是否有半写、完成说明是否丢失、Calendar conflict 是否同源、UI 是否存在双提交。每个 Critical/Important 发现先写最小失败测试，再让 Grok 修复；修复后由 Codex 重跑对应 focused tests。最终 review 必须达到 `0 Critical / 0 Important`，但这仍只属于工程门禁。

- [ ] **Step 3: 运行静态、全量、Release 和打包门禁**

Run:

```bash
git diff --check origin/main...HEAD
swift test
swift build -c release --product PersonalCalendar
./Scripts/verify-block-input-purity.sh --self-test
./Scripts/verify-block-input-purity.sh Sources/CalendarApp/Notes/BlockEditor
./Scripts/test-build-app-archive.sh
./Scripts/build-app.sh
codesign --verify --deep --strict dist/Jelly.app
```

Expected: 命令全部 exit 0；`dist/Jelly.app`、ZIP、DMG 来自当前 HEAD。记录 HEAD、App executable SHA-256、ZIP/DMG SHA-256、CDHash 和完整测试命令，不用测试条数替代产品结论。

- [ ] **Step 4: 在隔离数据目录准备代表性真实内容**

使用 `mktemp -d` 创建验收根目录，启动最终 `dist/Jelly.app` 时显式设置 `JELLY_ACCEPTANCE_DATA_DIRECTORY`；不得打开默认数据目录。准备至少：一篇模糊中文小事、一篇长中文个人计划、一篇已经足够具体的行动、已有 timed/untimed/recurrence/冲突日历数据，以及保存重启后的历史状态。

- [ ] **Step 5: 走智能主流程与无需追问流程**

在真实可用的 Apple 系统模型上观察并记录：点击到第一帧状态、真实等待、问题是否改变拆法、2～5 项结构是否合法、行动是否可独立完成、完成说明是否可观察、标题/说明/排序微调是否不被后续结果覆盖、只选择部分安排时最终结果是否精确。若设备或 locale 不支持，整行写 `UNVERIFIED_REAL_MODEL`，不得用 scripted 结果补成 PASS。

- [ ] **Step 6: 走失败、恢复与原子性流程**

真实操作：模型请求中取消、切手动模式、手工新增、第一次无效输出重试（仅在可控 diagnostic build 中）、局部重拆、工作台期间从另一窗口修改 Note、建议后新增冲突事项、Workspace 不可写、最终整单撤销。逐项确认失败时原笔记/日历无半成品，草稿仍可查看，恢复动作文案清楚。

- [ ] **Step 7: 验证真实数据往返、重启和跨模块影响**

创建后检查原 Note 插入位置和原文不变、完成说明次级显示、Calendar title 不含说明、Task completion 双向联动；导出再导入 Jelly Markdown/HTML；关闭重启确认 Task、说明、items、links 都在；Calendar 月/周/日抽屉、Note 编辑、Inspiration 主流程做局部回归。然后撤销并确认只移除本轮对象。

- [ ] **Step 8: 连续使用和视觉 9 分候选检查**

连续处理至少 6 篇含长中文的 Note，不重启 App。观察工作台打开、模型返回、编辑、滚动和关闭后的响应；检查 12～16 pt 字号没有突兀跳级、三分区一眼可辨、窄窗口不挤字、深浅主题、reduce motion、键盘焦点、VoiceOver 连续听感。主观手感、中文 IME 候选窗和 VoiceOver 若工具不能可靠观察，逐项标 `UNVERIFIED` 交给用户。

- [ ] **Step 9: 对每个产品实操缺陷闭环**

任何可复现缺陷：先添加最小自动化 regression（若可自动化）→ 让 Grok 修复 → Codex review → focused tests → 全量测试 → 重新打包 → 重走失败的真实路径。不得用源代码修复后的绿测关闭一个发生在旧 App 包里的失败。

- [ ] **Step 10: 写清三层结论并提交验收记录**

`docs/qa/2026-08-22-plan-and-schedule-product-run.md` 固定包含：

```markdown
## 工程验证通过
- commit / tests / release / package / signature evidence

## 产品实操通过
- only the exact packaged-App journeys actually replayed

## UNVERIFIED
- real model quality, IME, VoiceOver or subjective feel not directly observed

## 用户验收
- 待用户本人完成一个真实小事和一个需继续拆开的长想法；未确认
```

提交记录：

```bash
git add Tests/CalendarAppTests/DecompositionEndToEndTests.swift docs/qa/2026-08-22-plan-and-schedule-product-run.md
git commit -m "test(decomposition): record packaged app validation"
```

- [ ] **Step 11: 交给用户本人做两条 9 分验收旅程**

用户使用一个真实小事和一个较长、需要继续拆开的想法，判断四件事：问题是否有用、微调是否顺手、时间建议是否制造压力、视觉是否安静清楚。只有用户明确认可后才记录“用户验收通过”；否则保持 Goal active，把反馈变成新的失败场景继续修。

---

## Completion Gate

实现者只有在以下条件同时满足时才停止：Tasks 1～9 的当前状态有对应证据；分支只包含本功能与设计、计划、QA 三份文档；Grok 的实现经 Codex 累计 review 达到 `0 Critical / 0 Important`；全量测试、Release、打包和严格签名通过；最终包完成真实中文、真实日历、失败恢复、重启与连续使用实操；所有未能直接观察的体验项明确为 `UNVERIFIED`；用户收到准确的两条验收旅程。用户本人尚未认可时，不得关闭“9 分体验”Goal。
