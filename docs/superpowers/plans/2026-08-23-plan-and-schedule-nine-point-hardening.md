# 「拆开并安排」九分体验硬化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Jelly「拆开并安排」现有工作台的手动入口、草稿控制、视觉层级、时间建议保护和最终 App 失败恢复收口为 9 分体验候选。

**Architecture:** 沿用 `DecompositionWorkbenchModel`、`DecompositionDraft`、`CalendarProposalEngine`、`DecompositionOutputValidator` 和现有 Workspace 原子提交，不增加 provider、repository 或第二套状态机。体验状态只在当前工作台会话内维护；新增的 schedule lock 是候选草稿字段，不持久化到 Workspace。视觉仅复用 `CalendarTheme` 语义 token。

**Tech Stack:** Swift 6.3、SwiftUI、AppKit、Observation、Swift Testing、macOS 14+。

**Spec:** `docs/superpowers/specs/2026-08-23-plan-and-schedule-nine-point-hardening-design.md`

## Global Constraints

- 生产 App 仍只装配 Apple Foundation Models；production source 不得出现 MiniMax provider、key、base URL 或运行开关。
- 字号继续限制在 12、14、15、16 pt；不使用大标题、渐变、胶囊或装饰插画。
- 所有提交继续走单个 `.applyDecompositionPlan` Workspace command；任何失败都不得产生半写。
- 工作台草稿只在当前 sheet 会话存在；本轮不增加持久化 repository。
- 用户调整过的时间默认不得被重新建议覆盖。
- 普通 `swift test` 不联网、不依赖 appkey。
- 每个生产行为先写最小失败测试，确认 RED 后再实现；不得先改代码再补测试。
- Grok 负责实现；Codex 对每个提交独立检查 diff、失败测试证据、focused tests 和范围。

---

### Task 1: 建立草稿退出、手动首项和人工时间锁的状态合同

**Files:**
- Modify: `Sources/CalendarApp/Decomposition/DecompositionModels.swift`
- Modify: `Sources/CalendarApp/Decomposition/DecompositionWorkbenchModel.swift`
- Modify: `Tests/CalendarAppTests/DecompositionWorkbenchModelTests.swift`

**Interfaces:**
- Produces: `CandidateAction.scheduleLockedByUser: Bool`
- Produces: `DecompositionWorkbenchModel.hasMeaningfulDraft: Bool`
- Produces: `DecompositionWorkbenchModel.hasRunningRequest: Bool`
- Produces: `refreshCalendarProposals(overwriteUserAdjustments: Bool = false)`
- Produces: `beginManualCalendarProposal(id: UUID)`
- Consumes: existing `applyManualMode(reason:)`, `makeTimedProposal`, `CalendarProposalEngine.propose`

- [ ] **Step 1: 写草稿与手动首项失败测试**

在 `DecompositionWorkbenchModelTests` 添加：

```swift
@Test func unavailableModePreparesOneEditableActionAndMarksMeaningfulDraft() async throws {
    let fixture = try await WorkbenchModelFixture.make(
        planner: UnavailableDecompositionPlanner(reason: .deviceNotEligible)
    )
    #expect(fixture.model.hasMeaningfulDraft == false)
    await fixture.model.start()
    #expect(fixture.model.draft.mode == .manual(reason: .deviceNotEligible))
    #expect(fixture.model.draft.stage == .split)
    #expect(fixture.model.draft.candidates.count == 1)
    #expect(fixture.model.draft.candidates[0].title.isEmpty)
    #expect(fixture.model.draft.candidates[0].completionDescription.isEmpty)
    #expect(fixture.model.hasMeaningfulDraft)
}

@Test func meaningfulDraftTracksAnswerCandidatesAndReachedStagesWithoutPersistence() async throws {
    let fixture = try await WorkbenchModelFixture.make(planner: ScriptedWorkbenchPlanner())
    #expect(!fixture.model.hasMeaningfulDraft)
    fixture.model.updateAnswer("下周前完成")
    #expect(fixture.model.hasMeaningfulDraft)
}
```

- [ ] **Step 2: 运行 focused tests 确认 RED**

Run:

```bash
swift test --filter DecompositionWorkbenchModelTests.unavailableModePreparesOneEditableActionAndMarksMeaningfulDraft
swift test --filter DecompositionWorkbenchModelTests.meaningfulDraftTracksAnswerCandidatesAndReachedStagesWithoutPersistence
```

Expected: FAIL，因为 manual mode 仍为空，且两个状态属性不存在。

- [ ] **Step 3: 增加最小草稿状态实现**

在 model 暴露只读计算属性：

```swift
var hasRunningRequest: Bool {
    if case .running = requestState { return true }
    return false
}

var hasMeaningfulDraft: Bool {
    !draft.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !draft.candidates.isEmpty
        || draft.stage != .understand
}
```

把 manual candidate 构造提取为 model 内私有方法，并在 `applyManualMode` 为空时插入一项；不得调用会再次取消请求或清错误的 public `addManualCandidate()`：

```swift
private func makeBlankManualCandidate() -> CandidateAction {
    CandidateAction(
        id: uuid(), title: "", completionDescription: "",
        estimatedDuration: .minutes30,
        selectedForCreation: true, selectedForCalendar: false,
        titleLockedByUser: false, completionLockedByUser: false,
        sourceCandidateID: nil, proposal: nil
    )
}
```

- [ ] **Step 4: 写人工时间锁与无建议失败测试**

添加以下覆盖：

```swift
@Test func refreshKeepsUserAdjustedScheduleUnlessOverwriteIsExplicit() async throws {
    let fixture = try await WorkbenchModelFixture.splitWithCalendar()
    let first = try #require(fixture.model.draft.candidates.first)
    let chosen = fixture.date(hour: 16, minute: 30, dayOffset: 2)
    fixture.model.updateProposalTime(id: first.id, instant: chosen)
    let locked = try #require(fixture.model.draft.candidates.first?.proposal)
    #expect(fixture.model.draft.candidates[0].scheduleLockedByUser)

    fixture.model.refreshCalendarProposals()
    #expect(fixture.model.draft.candidates[0].proposal == locked)

    fixture.model.refreshCalendarProposals(overwriteUserAdjustments: true)
    #expect(fixture.model.draft.candidates[0].proposal != locked)
    #expect(!fixture.model.draft.candidates[0].scheduleLockedByUser)
}

@Test func nilProposalBecomesManualOnlyAfterExplicitBegin() async throws {
    let fixture = try await WorkbenchModelFixture.splitWithoutAvailableSlot()
    let first = try #require(fixture.model.draft.candidates.first)
    fixture.model.setSelectedForCalendar(id: first.id, selected: true)
    #expect(fixture.model.draft.candidates[0].proposal == nil)
    fixture.model.beginManualCalendarProposal(id: first.id)
    #expect(fixture.model.draft.candidates[0].proposal != nil)
    #expect(fixture.model.draft.candidates[0].scheduleLockedByUser)
}
```

- [ ] **Step 5: 运行时间锁测试确认 RED**

Run:

```bash
swift test --filter DecompositionWorkbenchModelTests.refreshKeepsUserAdjustedScheduleUnlessOverwriteIsExplicit
swift test --filter DecompositionWorkbenchModelTests.nilProposalBecomesManualOnlyAfterExplicitBegin
```

Expected: FAIL，因为候选没有 lock，刷新会覆盖全部，且没有手动开始 API。

- [ ] **Step 6: 实现时间锁且不改变 Workspace schema**

在 `CandidateAction` 增加默认值字段：

```swift
var scheduleLockedByUser: Bool = false
```

规则：

- `updateProposalDate`、`updateProposalTime` 和 `beginManualCalendarProposal` 成功后置 `true`。
- `updateDuration` 只有在调用前已经有 proposal 时置 `true`；拆开阶段只改预计时长不能阻止首次自动建议。
- `setSelectedForCalendar(false)` 清 proposal 并清 lock。
- `refreshCalendarProposals()` 跳过 locked 候选。
- `overwriteUserAdjustments == true` 时覆盖所有候选并把 lock 清为 `false`。
- model 输出生成、manual blank、局部重拆 replacement 的 lock 均为 `false`。

`beginManualCalendarProposal` 仅在选中创建、选中日历且 proposal 为空时，用现有 `defaultProposalDate`、`defaultProposalStartTime` 和 `makeTimedProposal` 生成一个明确由用户启动的 proposal。

- [ ] **Step 7: 运行 model suite**

Run:

```bash
swift test --filter DecompositionWorkbenchModelTests
```

Expected: PASS；若旧测试预期 manual candidates 为空，只按新规格更新该断言，不放宽其他门禁。

- [ ] **Step 8: 提交 Task 1**

```bash
git add Sources/CalendarApp/Decomposition/DecompositionModels.swift Sources/CalendarApp/Decomposition/DecompositionWorkbenchModel.swift Tests/CalendarAppTests/DecompositionWorkbenchModelTests.swift
git commit -m "feat(拆解): 保护草稿与人工时间"
```

---

### Task 2: 补齐可见继续、功能标题和防误关闭

**Files:**
- Modify: `Sources/CalendarApp/Decomposition/DecompositionWorkbenchView.swift`
- Modify: `Sources/CalendarApp/Decomposition/DecompositionConversationPane.swift`
- Modify: `Tests/CalendarAppTests/DecompositionWorkbenchInteractionTests.swift`
- Modify: `Tests/CalendarAppTests/DecompositionWorkbenchPresentationTests.swift`

**Interfaces:**
- Consumes: `model.hasMeaningfulDraft`, `model.hasRunningRequest`
- Produces: `DecompositionWorkbenchCopy.continueAnswer`
- Produces: view-local `requestClose()` and discard confirmation
- Produces: `DecompositionIdentifiedTextField.requestsInitialFocus`

- [ ] **Step 1: 写可见继续与统一提交失败测试**

添加 hosted interaction test：

```swift
@Test func answerHasVisibleContinueAndReturnUsesSameSubmission() async throws {
    let fixture = try await WorkbenchPresentationFixture.understandWithQuestion()
    let host = hostedWorkbench(fixture.model, size: DecompositionWorkbenchMetrics.targetSize)
    defer { host.window.orderOut(nil) }
    let button = try uniqueButton(identifier: "decomposition-answer-continue", in: host.view)
    #expect(button.title == "继续")
    #expect(!button.isEnabled)
    fixture.model.updateAnswer("下周前完成")
    host.layout()
    #expect(button.isEnabled)
}
```

另在 source contract 中断言按钮 action 和 text field `onSubmit` 都调用一个局部 `submitAnswer()`，防止两条逻辑漂移。

- [ ] **Step 2: 运行继续按钮测试确认 RED**

```bash
swift test --filter DecompositionWorkbenchPresentationTests.answerHasVisibleContinueAndReturnUsesSameSubmission
```

Expected: FAIL，按钮不存在。

- [ ] **Step 3: 实现可见继续与功能标题**

在 conversation pane 增加：

```swift
private var canSubmitAnswer: Bool {
    !model.draft.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !model.hasRunningRequest
        && !model.isCommitting
}

private func submitAnswer() {
    guard canSubmitAnswer else { return }
    Task { await model.submitAnswer(model.draft.answer) }
}
```

输入框和「继续」组成 `HStack`；按钮 identifier 为 `decomposition-answer-continue`。顶部左侧增加 16 pt semibold「拆开并安排」，步骤按钮继续 15 pt 以下，不增加 sheet 高度超过 8 pt。

- [ ] **Step 4: 写关闭语义失败测试**

在 interaction tests 增加三条。第一条使用可暂停 planner 证明 Escape 只停止请求：

```swift
@Test func escapeStopsRunningRequestBeforeClosing() async throws {
    let planner = SleepingWorkbenchPlanner()
    let fixture = try await WorkbenchInteractionFixture.make(planner: planner)
    var closed = false
    let host = hostedInteractionWorkbench(fixture.model, onCancel: { closed = true })
    defer { host.window.orderOut(nil) }
    let starting = Task { await fixture.model.start() }
    #expect(await waitUntil { fixture.model.hasRunningRequest })
    sendKey(escapeKey(in: host.window), in: host.window)
    #expect(await waitUntil { !fixture.model.hasRunningRequest })
    #expect(!closed)
    await starting.value
}

@Test func emptyWorkbenchClosesWithoutConfirmation() async throws {
    let fixture = try await WorkbenchInteractionFixture.make(planner: SleepingWorkbenchPlanner())
    var closeCount = 0
    let host = hostedInteractionWorkbench(fixture.model, onCancel: { closeCount += 1 })
    defer { host.window.orderOut(nil) }
    try #require(findButton(in: host.view, identifier: "decomposition-close")).performClick(nil)
    #expect(closeCount == 1)
}

@Test func meaningfulDraftRequiresExplicitDiscard() async throws {
    let fixture = try await WorkbenchInteractionFixture.make(planner: SleepingWorkbenchPlanner())
    fixture.model.updateAnswer("下周前完成")
    var closed = false
    let host = hostedInteractionWorkbench(fixture.model, onCancel: { closed = true })
    defer { host.window.orderOut(nil) }
    try #require(findButton(in: host.view, identifier: "decomposition-close")).performClick(nil)
    #expect(!closed)
    let dialog = try #require(NSApp.keyWindow)
    let discard = try #require(descendants(of: dialog.contentView!, as: NSButton.self).first {
        $0.title == "丢弃这次拆解"
    })
    discard.performClick(nil)
    #expect(await waitUntil { closed })
}
```

测试必须挂真实 `NSWindow` 并发送 cancel key equivalent；不得直接调用 model 假装走 UI。

- [ ] **Step 5: 运行关闭测试确认 RED**

```bash
swift test --filter DecompositionWorkbenchInteractionTests.escapeStopsRunningRequestBeforeClosing
swift test --filter DecompositionWorkbenchInteractionTests.meaningfulDraftRequiresExplicitDiscard
```

Expected: FAIL，当前 `handleEscape` 直接关闭非运行 sheet。

- [ ] **Step 6: 实现单一关闭入口**

在 view 中新增：

```swift
@State private var showsDiscardConfirmation = false

private func requestClose() {
    if model.hasRunningRequest {
        model.cancelRequest()
    } else if model.hasMeaningfulDraft {
        showsDiscardConfirmation = true
    } else {
        onCancel()
    }
}
```

关闭按钮和 Escape 都只调用 `requestClose()`。用 `confirmationDialog` 提供「继续编辑」和 role `.destructive` 的「丢弃这次拆解」；文案明确“这份草稿不会保存”。提交中仍禁止关闭。

- [ ] **Step 7: 让 manual 第一项获得焦点**

给 `DecompositionIdentifiedNSTextField` 增加 `requestsInitialFocus`，只在 window 没有有效 text responder 时调用 `makeFirstResponder`。`DecompositionIdentifiedTextField` 透传该值；ActionEditor 仅对 manual mode 的第一项标题传 `true`。不得抢走已存在的 IME/editor focus。

- [ ] **Step 8: 运行 interaction 与 presentation suites**

```bash
swift test --filter DecompositionWorkbenchInteractionTests
swift test --filter DecompositionWorkbenchPresentationTests
```

Expected: PASS；真实 keyboard test 仍覆盖 Tab / Shift-Tab / Space / Escape。

- [ ] **Step 9: 提交 Task 2**

```bash
git add Sources/CalendarApp/Decomposition/DecompositionWorkbenchView.swift Sources/CalendarApp/Decomposition/DecompositionConversationPane.swift Tests/CalendarAppTests/DecompositionWorkbenchInteractionTests.swift Tests/CalendarAppTests/DecompositionWorkbenchPresentationTests.swift
git commit -m "feat(拆解): 补齐继续与退出保护"
```

---

### Task 3: 强化来源边界、行动分组与中文输入保护

**Files:**
- Modify: `Sources/CalendarApp/Decomposition/DecompositionWorkbenchView.swift`
- Modify: `Sources/CalendarApp/Decomposition/DecompositionConversationPane.swift`
- Modify: `Sources/CalendarApp/Decomposition/DecompositionActionEditor.swift`
- Modify: `Tests/CalendarAppTests/DecompositionWorkbenchPresentationTests.swift`
- Modify: `Tests/CalendarAppTests/DecompositionWorkbenchInteractionTests.swift`

**Interfaces:**
- Consumes: `draft.source.selectedRange`, `CalendarTheme` semantic tokens
- Produces: `DecompositionWorkbenchCopy.sourceScope(_:)`
- Produces: single-line marked-text preservation

- [ ] **Step 1: 写来源范围和展开失败测试**

测试 whole note 与 selection 两种 fixture：

```swift
#expect(labels.contains("整篇笔记"))
#expect(labels.contains("所选文字"))
#expect(findButton(in: host.view, identifier: "decomposition-source-toggle")?.title == "展开来源")
```

点击后断言完整长中文出现在可访问文本中，再次点击变为「收起来源」。窄布局下来源 pane 仍不超过既定 max height，内部 ScrollView 可滚动。

- [ ] **Step 2: 运行来源测试确认 RED**

```bash
swift test --filter DecompositionWorkbenchPresentationTests.sourceShowsWholeOrSelectionScopeAndCanExpand
```

Expected: FAIL，当前固定 6 行且没有范围标签或 toggle。

- [ ] **Step 3: 实现来源展开**

ConversationPane 增加 `@State private var sourceExpanded = false`；默认 `.lineLimit(6)`，展开后 `.lineLimit(nil)`。范围文案只由 `selectedRange == nil` 决定，不重新读取 editor selection。

- [ ] **Step 4: 写行动语义和视觉合同失败测试**

断言：

- creation checkbox 的 `visualTitle == "创建"`，AX label 仍带候选标题。
- completion placeholder 是「做到什么算完成？」。
- 选中行动使用 `selectionFill` 与 `selectionOutline`，未选中不产生同权重边框。
- 字号只包含 12、14、15、16；仍无 gradient、largeTitle、Capsule。
- 次级操作与内容输入在不同 HStack/Group 中，展开行一次只存在一个 destructive 入口。

- [ ] **Step 5: 写单行 marked-text 失败测试**

给 `DecompositionIdentifiedTextField` 的 hosted AppKit test 注入一个可报告 `hasMarkedText == true` 的 field editor；在 SwiftUI binding 发生无关刷新时断言 `stringValue` 不被回写。测试结构沿用多行输入已有 marked-text 覆盖，不用真实 IME 代替工程回归。

- [ ] **Step 6: 运行行动与输入测试确认 RED**

```bash
swift test --filter DecompositionWorkbenchPresentationTests.actionRowsExposeClearCreationAndGroupedSecondaryControls
swift test --filter DecompositionWorkbenchInteractionTests.singleLineFieldDoesNotOverwriteMarkedText
```

Expected: FAIL，checkbox 无可见标题，placeholder 旧文案，单行 update 无 marked-text guard。

- [ ] **Step 7: 实现最小视觉和输入修复**

单行 update 与多行保持同一规则：

```swift
let hasMarkedText = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
if !hasMarkedText, field.stringValue != text {
    field.stringValue = text
}
```

行动行只复用 `selectionFill.opacity(...)`、`selectionOutline`、`subtleBorder`、`CalendarTheme.cornerRadius`。不要新建 color token。把标题/完成说明视为内容区，把时长、排序、更多归为次级控制区；「继续拆开」只在 intelligent mode 出现且保持清楚但不与主按钮同权重。

- [ ] **Step 8: 运行 presentation、interaction 和 accessibility suites**

```bash
swift test --filter DecompositionWorkbenchPresentationTests
swift test --filter DecompositionWorkbenchInteractionTests
swift test --filter BlockEditorAccessibilityTests
```

Expected: PASS。

- [ ] **Step 9: 提交 Task 3**

```bash
git add Sources/CalendarApp/Decomposition/DecompositionWorkbenchView.swift Sources/CalendarApp/Decomposition/DecompositionConversationPane.swift Sources/CalendarApp/Decomposition/DecompositionActionEditor.swift Tests/CalendarAppTests/DecompositionWorkbenchPresentationTests.swift Tests/CalendarAppTests/DecompositionWorkbenchInteractionTests.swift
git commit -m "feat(拆解): 强化来源与行动层级"
```

---

### Task 4: 让时间建议服从人工调整

**Files:**
- Modify: `Sources/CalendarApp/Decomposition/DecompositionScheduleEditor.swift`
- Modify: `Sources/CalendarApp/Decomposition/DecompositionWorkbenchView.swift`
- Modify: `Tests/CalendarAppTests/DecompositionWorkbenchPresentationTests.swift`
- Modify: `Tests/CalendarAppTests/DecompositionWorkbenchInteractionTests.swift`

**Interfaces:**
- Consumes: `scheduleLockedByUser`
- Consumes: `refreshCalendarProposals(overwriteUserAdjustments:)`
- Consumes: `beginManualCalendarProposal(id:)`

- [ ] **Step 1: 写无建议状态失败测试**

Hosted schedule fixture 让 proposal engine 无可用时段，断言：

```swift
#expect(findButton(in: host.view, identifier: "decomposition-choose-time-\(id)")?.title == "选择日期与时间")
#expect(findView(in: host.view, identifier: "decomposition-time-\(id)") == nil)
#expect(!accessibilityLabels(in: host.view).contains { $0.contains("09:00") })
```

点击后日期、时间、时长控件出现，model proposal 非 nil 且 locked。

- [ ] **Step 2: 写刷新保护失败测试**

准备两个日历候选，人工修改第一项，点击普通「重新建议时间」；断言第一项保持、第二项更新。存在 locked 项时出现明确次级「全部重新建议」；点击后两项更新。

- [ ] **Step 3: 运行 schedule tests 确认 RED**

```bash
swift test --filter DecompositionWorkbenchPresentationTests.noProposalShowsExplicitChooseTimeWithoutFakeNineAM
swift test --filter DecompositionWorkbenchInteractionTests.refreshTimeKeepsUserAdjustedRows
```

Expected: FAIL，当前 nil proposal 仍显示默认 chips，刷新覆盖全部。

- [ ] **Step 4: 实现 schedule UI**

规则：

- `proposal == nil`：显示解释「未来七天没有合适空档」和 bordered「选择日期与时间」。
- `proposal != nil`：显示摘要与现有 date/time/duration controls。
- 普通按钮始终调用 `overwriteUserAdjustments: false`。
- 只有存在 locked schedule 时才显示 menu/次级 action「全部重新建议」；help 明确会覆盖人工调整。
- 人工调整项显示 12 pt 的「已调整」文字，不只用颜色或图标表达。

- [ ] **Step 5: 强化安排分组但不增加视觉噪声**

每项安排使用现有 `elevatedSurface`/`subtleBorder` 建立组边界，垂直间距 12～16 pt；不使用渐变、阴影堆叠或新增 card component。底部结果区继续固定 64 pt。

- [ ] **Step 6: 运行 calendar proposal 与 workbench suites**

```bash
swift test --filter CalendarProposalEngineTests
swift test --filter DecompositionWorkbenchModelTests
swift test --filter DecompositionWorkbenchPresentationTests
swift test --filter DecompositionWorkbenchInteractionTests
```

Expected: PASS。

- [ ] **Step 7: 提交 Task 4**

```bash
git add Sources/CalendarApp/Decomposition/DecompositionScheduleEditor.swift Sources/CalendarApp/Decomposition/DecompositionWorkbenchView.swift Tests/CalendarAppTests/DecompositionWorkbenchPresentationTests.swift Tests/CalendarAppTests/DecompositionWorkbenchInteractionTests.swift
git commit -m "feat(拆解): 保护人工安排"
```

---

### Task 5: 就地说明阻塞原因并回归失败恢复

**Files:**
- Modify: `Sources/CalendarApp/Decomposition/DecompositionActionEditor.swift`
- Modify: `Sources/CalendarApp/Decomposition/DecompositionWorkbenchView.swift`
- Modify: `Sources/CalendarApp/Decomposition/DecompositionWorkbenchModel.swift`
- Modify: `Tests/CalendarAppTests/DecompositionWorkbenchPresentationTests.swift`
- Modify: `Tests/CalendarAppTests/DecompositionWorkbenchModelTests.swift`
- Modify: `Tests/CalendarAppTests/DecompositionEndToEndTests.swift`

**Interfaces:**
- Produces: `DecompositionWorkbenchModel.firstBlockingCandidateID: UUID?`
- Consumes: existing `advanceBlockingReason`, `commitBlockingReason`, `lastRecoverableError`

- [ ] **Step 1: 写第一处错误定位失败测试**

构造三个候选：第一项完整、第二项缺完成说明、第三项缺标题。断言 model 返回第二项 ID；hosted view 展开第二项、给对应字段 error AX value，并保留底栏中文原因。修好第二项后，定位移动到第三项。

- [ ] **Step 2: 运行定位测试确认 RED**

```bash
swift test --filter DecompositionWorkbenchPresentationTests.blockingReasonSelectsAndMarksFirstInvalidCandidate
```

Expected: FAIL，没有 candidate-level 定位。

- [ ] **Step 3: 实现确定性定位**

`firstBlockingCandidateID` 只按候选顺序返回首个 selected 且缺 title/completion/proposal 的 ID；来源变化、无选择和持久化失败返回 nil。ActionEditor 在 blocking ID 改变时展开对应行；字段用 `theme.error` 的细下划线/边框和文字标签，不只变红。

- [ ] **Step 4: 写冲突与重试回归**

覆盖：

- 晚到日历冲突后 stage 仍为 schedule，候选、proposal、lock 不变；普通刷新只处理 unlocked。
- source changed 后候选和回答仍可读取，recommit 继续被门禁，Store revision 不变。
- persistence failure 后草稿仍在，第二次 store 成功时可提交一次，无 duplicate。

- [ ] **Step 5: 运行失败恢复 tests**

```bash
swift test --filter DecompositionWorkbenchModelTests
swift test --filter DecompositionEndToEndTests
swift test --filter DecompositionWorkspaceStoreTests
```

Expected: PASS；任何半写、草稿清空或重复提交都是阻塞缺陷。

- [ ] **Step 6: 提交 Task 5**

```bash
git add Sources/CalendarApp/Decomposition/DecompositionActionEditor.swift Sources/CalendarApp/Decomposition/DecompositionWorkbenchView.swift Sources/CalendarApp/Decomposition/DecompositionWorkbenchModel.swift Tests/CalendarAppTests/DecompositionWorkbenchPresentationTests.swift Tests/CalendarAppTests/DecompositionWorkbenchModelTests.swift Tests/CalendarAppTests/DecompositionEndToEndTests.swift
git commit -m "feat(拆解): 就地定位失败并保留草稿"
```

---

### Task 6: 工程门禁、Impeccable 检测与最终 App 产品实操

**Files:**
- Modify: `docs/qa/2026-08-22-plan-and-schedule-product-run.md`
- Modify: `.impeccable/critique/2026-08-23T15-32-00Z__app-decomposition-decompositionworkbenchview-swift.md` only if factual post-fix notes are appended; do not rewrite the original score
- Create: `.impeccable/critique/<post-fix timestamp>__app-decomposition-decompositionworkbenchview-swift.md` through the Impeccable storage helper

**Interfaces:**
- Consumes: all Tasks 1–5
- Consumes: separate MiniMax plan `docs/superpowers/plans/2026-08-23-decomposition-minimax-live-eval.md`
- Produces: refreshed final App, hashes, product-run evidence, remaining `UNVERIFIED`

- [ ] **Step 1: Grok 做范围自检，Codex 独立 review**

Run:

```bash
git diff --check
git diff --stat 0c17dd4...HEAD
git diff --name-only 0c17dd4...HEAD
rg -n "MINIMAX_API_KEY|api\.minimaxi\.com|MiniMax-M3" Sources Package.swift
```

Expected: diff 只包含本规格、计划、工作台相关 production/tests、MiniMax test-only files/scripts 和 QA；production scan 无命中。Codex 对 dirty close、marked text、schedule lock、原子写、late conflict 和 double submit 给出 `0 Critical / 0 Important` 才继续。

- [ ] **Step 2: 运行 focused 和 full gates**

```bash
swift test --filter DecompositionWorkbenchModelTests
swift test --filter DecompositionWorkbenchPresentationTests
swift test --filter DecompositionWorkbenchInteractionTests
swift test --filter DecompositionEndToEndTests
swift test --filter DecompositionWorkspaceStoreTests
swift test --filter CalendarProposalEngineTests
swift test
swift build -c release --product PersonalCalendar
./Scripts/verify-block-input-purity.sh --self-test
./Scripts/verify-block-input-purity.sh Sources/CalendarApp/Notes/BlockEditor
./Scripts/test-build-app-archive.sh
./Scripts/build-app.sh
codesign --verify --deep --strict --verbose=2 dist/Jelly.app
```

Expected: 全部退出 0。任何修复后只跑 focused 不足以关闭任务。

- [ ] **Step 3: 运行 Impeccable post-fix detector**

```bash
node /Users/oreal/.agents/skills/impeccable/scripts/detect.mjs --json Sources/CalendarApp/Decomposition/DecompositionWorkbenchView.swift Sources/CalendarApp/Decomposition/DecompositionConversationPane.swift Sources/CalendarApp/Decomposition/DecompositionActionEditor.swift Sources/CalendarApp/Decomposition/DecompositionScheduleEditor.swift
```

记录 detector 对 SwiftUI 的覆盖边界；不得把 `[]` 写成原生视觉 PASS。重新做独立设计审查并通过 storage helper 写 post-fix snapshot；目标至少消除两个 P1，分数只按真实审查给出，不为达到数字修改量表。

- [ ] **Step 4: 用最终 App 走普通用户主流程**

使用 `mktemp -d` 和 `JELLY_ACCEPTANCE_DATA_DIRECTORY`，不得打开默认数据目录。逐项：

1. manual unavailable 打开后第一项获得焦点；输入两项并提交。
2. question fixture/可用 diagnostic path 中点击「继续」，验证 Return 同结果。
3. 编辑候选和时间后 Escape：先停止，再弹丢弃确认；继续编辑后内容仍在。
4. 长整篇和真实选区分别显示范围并展开完整来源。
5. 人工时间普通刷新保持；全部刷新只有明确选择后覆盖。
6. 无建议只出现「选择日期与时间」，选择后提交精确时间。
7. 成功反馈、Calendar completion sync、一次性撤销、退出重启。

- [ ] **Step 5: 走双实例失败恢复**

从同一个隔离数据目录启动两个最终 App 实例，分别使用唯一 bundle copy/name 让自动化可区分。实例 A 打开工作台，实例 B 修改来源 Note；A 提交必须整单拒绝且候选仍可查看。重复准备晚到 calendar conflict；A 必须回到 schedule，人工时间与 lock 保留。停止两个实例后检查 JSON、journal 与操作日志无半写。

- [ ] **Step 6: 走视觉、连续使用和真人边界**

最终 App 覆盖 light/dark、960×680、720×560、长中文、6 篇连续处理、Reduce Motion。记录点击到可见反馈、焦点、滚动和明显卡顿，不把工具等待算成产品延迟。中文 IME 候选、VoiceOver 连续听感和主观安静程度如果 Codex 无法可靠观察，继续写 `UNVERIFIED` 并交用户本人。

- [ ] **Step 7: 更新 QA 并提交 Task 6**

QA 分开写：工程验证、MiniMax 真实 LLM 回归、最终 App 产品实操、Apple 模型 `UNVERIFIED`、真人验收 `UNVERIFIED`。记录新 HEAD、App/ZIP/DMG hashes 和 codesign CDHash。

```bash
git add docs/qa/2026-08-22-plan-and-schedule-product-run.md .impeccable/critique
git commit -m "test(拆解): 完成九分体验硬化验收"
```

---

## Plan Self-Review

- Spec coverage: 手动入口、继续按钮、退出保护、来源展开、视觉分区、marked text、时间锁、无建议、错误定位、冲突恢复和最终 App 验收均映射到 Tasks 1–6。
- Deferred scope: draft persistence、通用 provider、GoalBoard 同步、大数据专项和 Apple provider 优化没有进入任务。
- Type consistency: `scheduleLockedByUser`、`hasMeaningfulDraft`、`hasRunningRequest`、`refreshCalendarProposals(overwriteUserAdjustments:)`、`beginManualCalendarProposal(id:)`、`firstBlockingCandidateID` 在首次产生后只用同一名称。
- Placeholder scan: 本计划没有 TBD/TODO；产品实操步骤明确输入、预期和证据边界。

## Execution Handoff

用户已经选择 Grok 执行、Codex 监督与复审。Grok 必须按 Task 1 → 6 顺序执行；每个 Task 独立提交并报告 RED、GREEN、diff 和剩余风险。Codex 在当前 task 中逐提交复核，不把 Grok 报告直接当完成证据。
