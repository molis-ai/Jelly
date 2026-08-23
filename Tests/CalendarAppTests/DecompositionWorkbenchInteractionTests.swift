import AppKit
import CalendarDomain
import Foundation
import SwiftUI
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("DecompositionWorkbenchInteractionTests", .serialized)
@MainActor
struct DecompositionWorkbenchInteractionTests {
    @Test func keyboardJourneyEditsLocksSplitsSchedulesAndCommitsWithoutDoubleSubmit() async throws {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000911")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000912")!
        let splitA = UUID(uuidString: "00000000-0000-0000-0000-000000000913")!
        let splitB = UUID(uuidString: "00000000-0000-0000-0000-000000000914")!
        let fixture = try await WorkbenchInteractionFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.ask(question: "完成后最重要的结果是什么？", quickAnswers: ["拿到确认"])),
                .candidates([
                    PlannerCandidate(
                        existingID: nil,
                        title: "打电话确认",
                        completionDescription: "拿到明确上门时间",
                        estimatedMinutes: 15
                    ),
                    PlannerCandidate(
                        existingID: nil,
                        title: "准备材料",
                        completionDescription: "把证件放一起",
                        estimatedMinutes: 30
                    )
                ]),
                .candidates([
                    PlannerCandidate(
                        existingID: nil,
                        title: "拨打电话",
                        completionDescription: "打通物业电话",
                        estimatedMinutes: 15
                    ),
                    PlannerCandidate(
                        existingID: nil,
                        title: "记下时间",
                        completionDescription: "把约定写进笔记",
                        estimatedMinutes: 15
                    )
                ])
            ]),
            uuid: SequentialInteractionUUID([first, second, splitA, splitB]).next
        )
        await fixture.model.start()
        var committedResults: [DecompositionCommitResult] = []
        let host = hostedInteractionWorkbench(fixture.model, onCommitted: { committedResults.append($0) })
        defer { host.window.orderOut(nil) }
        host.view.layoutSubtreeIfNeeded()

        let answer = try #require(await waitForField(in: host.view, identifier: "decomposition-answer"))
        #expect(host.window.makeFirstResponder(answer))
        try typeIntoFieldEditor("拿到确认", window: host.window)
        #expect(await waitUntil { fixture.model.draft.answer == "拿到确认" })
        sendKey(returnKey(in: host.window), in: host.window)
        #expect(await waitUntil { fixture.model.draft.stage == .split && fixture.model.draft.candidates.count == 2 })

        let titleIdentifier = "decomposition-title-\(first.uuidString)"
        let titleField = try #require(await waitForField(in: host.view, identifier: titleIdentifier))
        #expect(titleField.canBecomeKeyView)
        #expect(titleField.acceptsFirstResponder)
        try await tabUntil(in: host.window, view: host.view, target: "first title") { responder in
            isFieldEditor(of: titleField, responder: responder) || responder === titleField
        }
        sendKey(tabKey(in: host.window, shift: true), in: host.window)
        host.view.layoutSubtreeIfNeeded()
        #expect(
            !(isFieldEditor(of: titleField, responder: host.window.firstResponder) || host.window.firstResponder === titleField)
        )
        try await tabUntil(in: host.window, view: host.view, target: "first title after reverse tab") { responder in
            isFieldEditor(of: titleField, responder: responder) || responder === titleField
        }
        try typeIntoFieldEditor("手改标题", window: host.window)
        #expect(await waitUntil {
            fixture.model.draft.candidates.first?.title == "手改标题"
                && fixture.model.draft.candidates.first?.titleLockedByUser == true
        })
        #expect(fixture.model.draft.candidates[0].title == "手改标题")
        #expect(fixture.model.draft.candidates[0].titleLockedByUser)

        let moveDown = try #require(findButton(
            in: host.view,
            identifier: "decomposition-move-down-\(first.uuidString)"
        ))
        try await tabUntil(in: host.window, view: host.view, target: "move down") { responder in
            isControl(moveDown, responder: responder)
        }
        sendKey(spaceKey(in: host.window), in: host.window)
        #expect(await waitUntil { fixture.model.draft.candidates.map(\.id) == [second, first] })

        let split = try #require(findButton(
            in: host.view,
            identifier: "decomposition-split-\(first.uuidString)"
        ))
        try await tabUntil(in: host.window, view: host.view, target: "continue split") { responder in
            isControl(split, responder: responder)
        }
        sendKey(spaceKey(in: host.window), in: host.window)
        #expect(await waitUntil { fixture.model.draft.candidates.count >= 3 })
        #expect(fixture.model.draft.candidates[0].title == "准备材料")

        let advance = try #require(findButton(in: host.view, identifier: "decomposition-advance"))
        try await tabUntil(in: host.window, view: host.view, target: "confirm actions") { responder in
            isControl(advance, responder: responder)
        }
        sendKey(spaceKey(in: host.window), in: host.window)
        #expect(await waitUntil { fixture.model.draft.stage == .schedule })
        #expect(await waitUntil {
            host.view.layoutSubtreeIfNeeded()
            return findCheckbox(
                in: host.view,
                identifier: "decomposition-calendar-\(second.uuidString)"
            ) != nil
        })

        let calendarToggle = try #require(findCheckbox(
            in: host.view,
            identifier: "decomposition-calendar-\(second.uuidString)"
        ))
        #expect(calendarToggle.accessibilityRole() == .checkBox)
        #expect(calendarToggle.isHidden == false)
        #expect(calendarToggle.window === host.window)
        #expect(calendarToggle.acceptsFirstResponder)
        #expect(calendarToggle.canBecomeKeyView)
        try await tabUntil(in: host.window, view: host.view, target: "calendar toggle") { responder in
            isControl(calendarToggle, responder: responder)
        }
        let calendarWasOn = fixture.model.draft.candidates.first(where: { $0.id == second })?.selectedForCalendar == true
        sendKey(spaceKey(in: host.window), in: host.window)
        #expect(await waitUntil {
            fixture.model.draft.candidates.first(where: { $0.id == second })?.selectedForCalendar == !calendarWasOn
        })
        host.view.layoutSubtreeIfNeeded()
        let toggled = try #require(findCheckbox(
            in: host.view,
            identifier: "decomposition-calendar-\(second.uuidString)"
        ))
        #expect(calendarMembership(from: toggled) == (calendarWasOn ? "未加入" : "已加入"))
        if fixture.model.draft.candidates.first(where: { $0.id == second })?.selectedForCalendar == true {
            sendKey(spaceKey(in: host.window), in: host.window)
            #expect(await waitUntil {
                fixture.model.draft.candidates.first(where: { $0.id == second })?.selectedForCalendar == false
            })
        }
        let calendarOff = try #require(findCheckbox(
            in: host.view,
            identifier: "decomposition-calendar-\(second.uuidString)"
        ))
        #expect(fixture.model.draft.candidates.first(where: { $0.id == second })?.selectedForCalendar == false)
        #expect(calendarMembership(from: calendarOff) == "未加入")

        let generation = fixture.store.statePublicationGeneration
        #expect(await waitUntil {
            host.view.layoutSubtreeIfNeeded()
            return findButton(in: host.view, identifier: "decomposition-commit")?.isEnabled == true
        })
        sendKey(returnKey(in: host.window), in: host.window)
        #expect(await waitUntil {
            !committedResults.isEmpty && fixture.store.statePublicationGeneration == generation + 1
        })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(committedResults.count == 1)
        guard case let .committed(created, scheduled, _) = committedResults[0] else {
            Issue.record("expected committed plan, got \(committedResults[0])")
            return
        }
        #expect(created == 3)
        #expect(scheduled == 0)
        #expect(fixture.store.statePublicationGeneration == generation + 1)
        let titles = fixture.store.state.notes[fixture.noteID]?.document.blocks.map {
            $0.inlineContent.spans.map(\.text).joined()
        } ?? []
        #expect(titles.contains("准备材料"))
        #expect(titles.contains("拨打电话"))
        #expect(titles.contains("记下时间"))
    }

    @Test func keyboardReorderUsesMoveButtonsAndDoesNotRequireTheDragHandle() async throws {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000931")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000932")!
        let fixture = try await WorkbenchInteractionFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates([
                    PlannerCandidate(
                        existingID: nil,
                        title: "第一项",
                        completionDescription: "第一项完成说明",
                        estimatedMinutes: 15
                    ),
                    PlannerCandidate(
                        existingID: nil,
                        title: "第二项",
                        completionDescription: "第二项完成说明",
                        estimatedMinutes: 30
                    )
                ])
            ]),
            uuid: SequentialInteractionUUID([first, second]).next
        )
        await fixture.model.start()
        let host = hostedInteractionWorkbench(fixture.model)
        defer { host.window.orderOut(nil) }
        host.view.layoutSubtreeIfNeeded()

        #expect(await waitUntil {
            host.view.layoutSubtreeIfNeeded()
            return descendants(of: host.view, as: NSView.self).contains {
                $0.accessibilityIdentifier() == "decomposition-drag-handle-\(first.uuidString)"
            }
        })
        let handle = try #require(descendants(of: host.view, as: NSView.self).first {
            $0.accessibilityIdentifier() == "decomposition-drag-handle-\(first.uuidString)"
        })
        #expect(handle.isAccessibilityElement() != true)
        #expect(handle.canBecomeKeyView == false)

        let moveDown = try #require(findButton(
            in: host.view,
            identifier: "decomposition-move-down-\(first.uuidString)"
        ))
        moveDown.performClick(moveDown)
        #expect(await waitUntil { fixture.model.draft.candidates.map(\.id) == [second, first] })
        host.view.layoutSubtreeIfNeeded()

        let moveUp = try #require(findButton(
            in: host.view,
            identifier: "decomposition-move-up-\(first.uuidString)"
        ))
        moveUp.performClick(moveUp)
        #expect(await waitUntil { fixture.model.draft.candidates.map(\.id) == [first, second] })
    }

    @Test func modelResultDoesNotStealTitleFocusAndEscapeDoesNotWrite() async throws {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000921")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000922")!
        let planner = DualShotSplitPlanner()
        let fixture = try await WorkbenchInteractionFixture.make(
            planner: planner,
            uuid: SequentialInteractionUUID([first, second]).next
        )
        await fixture.model.start()
        var cancelled = false
        let host = hostedInteractionWorkbench(fixture.model, onCancel: { cancelled = true })
        defer { host.window.orderOut(nil) }

        let titleField = try #require(await waitForField(
            in: host.view,
            identifier: "decomposition-title-\(first.uuidString)"
        ))
        #expect(host.window.makeFirstResponder(titleField))
        try typeIntoFieldEditor("正在编辑", window: host.window)
        #expect(await waitUntil {
            fixture.model.draft.candidates.first?.title == "正在编辑"
                && fixture.model.draft.candidates.first?.titleLockedByUser == true
        })

        host.view.layoutSubtreeIfNeeded()
        let split = try #require(findButton(
            in: host.view,
            identifier: "decomposition-split-\(second.uuidString)"
        ))
        split.performClick(split)
        await planner.waitUntilStarted(count: 1)
        #expect(
            host.window.firstResponder === titleField
                || host.window.firstResponder === titleField.currentEditor()
        )
        await planner.resumeOldest([
            PlannerCandidate(
                existingID: nil,
                title: "拆开后的第一项",
                completionDescription: "完成第一项",
                estimatedMinutes: 15
            ),
            PlannerCandidate(
                existingID: nil,
                title: "拆开后的第二项",
                completionDescription: "完成第二项",
                estimatedMinutes: 15
            )
        ])
        #expect(await waitUntil {
            fixture.model.draft.candidates.contains { $0.title == "拆开后的第一项" }
        })
        #expect(
            host.window.firstResponder === titleField
                || host.window.firstResponder === titleField.currentEditor()
        )

        let generation = fixture.store.statePublicationGeneration
        sendKey(escapeKey(in: host.window), in: host.window)
        #expect(!cancelled)
        let discard = try #require(await waitForButtonTitled("丢弃这次拆解"))
        #expect(findButtonTitled("继续编辑") != nil)
        discard.performClick(nil)
        #expect(await waitUntil { cancelled })
        #expect(fixture.store.statePublicationGeneration == generation)
        #expect(fixture.store.state.notes[fixture.noteID]?.document.blocks.count == 1)
    }

    @Test func commitDisablesMutatingControlsAndIgnoresASecondClick() async throws {
        let fixture = try await WorkbenchInteractionFixture.readyToCommit()
        var committedResults: [DecompositionCommitResult] = []
        let host = hostedInteractionWorkbench(fixture.model, onCommitted: { committedResults.append($0) })
        defer { host.window.orderOut(nil) }
        host.view.layoutSubtreeIfNeeded()

        let advance = try #require(findButton(in: host.view, identifier: "decomposition-advance"))
        advance.performClick(advance)
        #expect(await waitUntil {
            host.view.layoutSubtreeIfNeeded()
            return fixture.model.draft.stage == .schedule
                && findButton(in: host.view, identifier: "decomposition-commit") != nil
        })

        let generationBefore = fixture.store.statePublicationGeneration
        let saveCountBefore = await fixture.repository.saveCount
        await fixture.repository.suspendNextSave()
        let commit = try #require(findButton(in: host.view, identifier: "decomposition-commit"))
        commit.performClick(commit)
        await fixture.repository.waitForSaveToStart()
        #expect(await waitUntil { fixture.model.isCommitting })
        #expect(await waitUntil {
            host.view.layoutSubtreeIfNeeded()
            return findButton(in: host.view, identifier: "decomposition-commit")?.isEnabled == false
                && findButton(in: host.view, identifier: "decomposition-close")?.isEnabled == false
                && findButton(in: host.view, identifier: "decomposition-stage-0")?.isEnabled == false
                && findButton(in: host.view, identifier: "decomposition-stage-1")?.isEnabled == false
                && findButton(in: host.view, identifier: "decomposition-stage-2")?.isEnabled == false
        })

        host.view.layoutSubtreeIfNeeded()
        let currentCommit = try #require(findButton(in: host.view, identifier: "decomposition-commit"))
        let close = try #require(findButton(in: host.view, identifier: "decomposition-close"))
        let stage0 = try #require(findButton(in: host.view, identifier: "decomposition-stage-0"))
        let stage1 = try #require(findButton(in: host.view, identifier: "decomposition-stage-1"))
        let stage2 = try #require(findButton(in: host.view, identifier: "decomposition-stage-2"))
        #expect(!currentCommit.isEnabled)
        #expect(!close.isEnabled)
        #expect(!stage0.isEnabled)
        #expect(!stage1.isEnabled)
        #expect(!stage2.isEnabled)
        if let firstID = fixture.model.draft.candidates.first?.id,
           let calendar = findCheckbox(
            in: host.view,
            identifier: "decomposition-calendar-\(firstID.uuidString)"
           ) {
            #expect(!calendar.isEnabled)
        }

        commit.performClick(commit)
        _ = host.window.performKeyEquivalent(with: returnKey(in: host.window))
        await fixture.repository.resumeSave()
        #expect(await waitUntil {
            !committedResults.isEmpty && fixture.store.statePublicationGeneration == generationBefore + 1
        })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(committedResults.count == 1)
        guard case .committed = committedResults[0] else {
            Issue.record("expected committed plan, got \(committedResults[0])")
            return
        }
        #expect(await fixture.repository.saveCount == saveCountBefore + 1)
        #expect(fixture.store.statePublicationGeneration == generationBefore + 1)
        #expect(fixture.store.state.notes[fixture.noteID]?.document.blocks.count == 3)
        #expect(fixture.model.isCommitting == false)
    }

    @Test func commitDisablesTitleFieldAndIgnoresTypedCharactersWhilePending() async throws {
        let fixture = try await WorkbenchInteractionFixture.readyToCommit()
        #expect(fixture.model.draft.stage == .split)
        let firstID = try #require(fixture.model.draft.candidates.first?.id)
        let originalTitle = try #require(fixture.model.draft.candidates.first?.title)
        let host = hostedInteractionWorkbench(fixture.model)
        defer { host.window.orderOut(nil) }
        host.view.layoutSubtreeIfNeeded()

        let titleIdentifier = "decomposition-title-\(firstID.uuidString)"
        _ = try #require(await waitForField(in: host.view, identifier: titleIdentifier))

        fixture.model.advanceToSchedule()
        await fixture.repository.suspendNextSave()
        defer {
            Task { await fixture.repository.resumeSave() }
        }
        let commitTask = Task { await fixture.model.commit() }
        #expect(await waitUntil { fixture.model.isCommitting })
        fixture.model.returnToStage(.split)
        #expect(fixture.model.draft.stage == .split)
        host.view.layoutSubtreeIfNeeded()

        let titleField = try #require(await waitForField(in: host.view, identifier: titleIdentifier))
        #expect(titleField.isEnabled == false)
        #expect(titleField.acceptsFirstResponder == false)
        #expect(titleField.canBecomeKeyView == false)
        #expect(titleField.refusesFirstResponder == true)
        _ = host.window.makeFirstResponder(titleField)

        sendKey(characterKey("x", in: host.window), in: host.window)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fixture.model.draft.candidates.first(where: { $0.id == firstID })?.title == originalTitle)

        await fixture.repository.resumeSave()
        let result = await commitTask.value
        guard case .committed = result else {
            Issue.record("expected committed plan, got \(result)")
            return
        }
        #expect(fixture.model.isCommitting == false)
        #expect(fixture.model.draft.candidates.first(where: { $0.id == firstID })?.title == originalTitle)
    }

    @Test func escapeStopsRunningRequestButCloseCancelsAndClosesInOneClick() async throws {
        let planner = CancellableLongClarificationPlanner()
        let fixture = try await WorkbenchInteractionFixture.make(planner: planner)
        var cancelCount = 0
        let host = hostedInteractionWorkbench(fixture.model, onCancel: { cancelCount += 1 })
        defer { host.window.orderOut(nil) }
        host.view.layoutSubtreeIfNeeded()

        let generation = fixture.store.statePublicationGeneration
        let originalBlockCount = fixture.store.state.notes[fixture.noteID]?.document.blocks.count ?? 0

        let firstStart = Task { await fixture.model.start() }
        await planner.waitUntilStarted(count: 1)
        #expect(await waitUntil {
            if case .running = fixture.model.requestState { return true }
            return false
        })
        sendKey(escapeKey(in: host.window), in: host.window)
        #expect(await waitUntil {
            if case .idle = fixture.model.requestState { return true }
            return false
        })
        #expect(cancelCount == 0)
        await firstStart.value

        let secondStart = Task { await fixture.model.start() }
        await planner.waitUntilStarted(count: 2)
        #expect(await waitUntil {
            if case .running = fixture.model.requestState { return true }
            return false
        })
        host.view.layoutSubtreeIfNeeded()
        let close = try #require(findButton(in: host.view, identifier: "decomposition-close"))
        close.performClick(close)
        #expect(await waitUntil {
            if case .idle = fixture.model.requestState { return true }
            return false
        })
        #expect(await waitUntil { cancelCount == 1 })
        await secondStart.value

        #expect(fixture.store.statePublicationGeneration == generation)
        #expect(fixture.store.state.notes[fixture.noteID]?.document.blocks.count == originalBlockCount)
        #expect(originalBlockCount == 1)
    }

    @Test func escapeStopsRunningRequestBeforeClosing() async throws {
        let planner = CancellableLongClarificationPlanner()
        let fixture = try await WorkbenchInteractionFixture.make(planner: planner)
        var closed = false
        let host = hostedInteractionWorkbench(fixture.model, onCancel: { closed = true })
        defer { host.window.orderOut(nil) }
        let starting = Task { await fixture.model.start() }
        await planner.waitUntilStarted(count: 1)
        #expect(await waitUntil { fixture.model.hasRunningRequest })
        sendKey(escapeKey(in: host.window), in: host.window)
        #expect(await waitUntil { !fixture.model.hasRunningRequest })
        #expect(!closed)
        await starting.value
    }

    @Test func emptyWorkbenchClosesWithoutConfirmation() async throws {
        let fixture = try await WorkbenchInteractionFixture.make(planner: CancellableLongClarificationPlanner())
        var closeCount = 0
        let host = hostedInteractionWorkbench(fixture.model, onCancel: { closeCount += 1 })
        defer { host.window.orderOut(nil) }
        try #require(findButton(in: host.view, identifier: "decomposition-close")).performClick(nil)
        #expect(closeCount == 1)
        #expect(findButtonTitled("丢弃这次拆解") == nil)
    }

    @Test func meaningfulDraftRequiresExplicitDiscard() async throws {
        let fixture = try await WorkbenchInteractionFixture.make(planner: CancellableLongClarificationPlanner())
        fixture.model.updateAnswer("下周前完成")
        var closed = false
        let host = hostedInteractionWorkbench(fixture.model, onCancel: { closed = true })
        defer { host.window.orderOut(nil) }
        try #require(findButton(in: host.view, identifier: "decomposition-close")).performClick(nil)
        #expect(!closed)
        let discard = try #require(await waitForButtonTitled("丢弃这次拆解"))
        #expect(findButtonTitled("继续编辑") != nil)
        #expect(discardConfirmationMentionsUnsavedDraft())
        #expect(fixture.model.draft.answer == "下周前完成")
        discard.performClick(nil)
        #expect(await waitUntil { closed })
    }

    @Test func escapeOnMeaningfulDraftShowsDiscardConfirmationInsteadOfClosing() async throws {
        let fixture = try await WorkbenchInteractionFixture.make(planner: CancellableLongClarificationPlanner())
        fixture.model.updateAnswer("下周前完成")
        var closed = false
        let host = hostedInteractionWorkbench(fixture.model, onCancel: { closed = true })
        defer { host.window.orderOut(nil) }
        sendKey(escapeKey(in: host.window), in: host.window)
        #expect(!closed)
        let discard = try #require(await waitForButtonTitled("丢弃这次拆解"))
        #expect(findButtonTitled("继续编辑") != nil)
        #expect(discardConfirmationMentionsUnsavedDraft())
        discard.performClick(nil)
        #expect(await waitUntil { closed })
    }

    @Test func manualFirstTitleTakesInitialFocusWhenWindowHasNoTextResponder() async throws {
        let fixture = try await WorkbenchInteractionFixture.make(
            planner: UnavailableDecompositionPlanner(reason: .deviceNotEligible)
        )
        await fixture.model.start()
        let first = try #require(fixture.model.draft.candidates.first)
        let host = hostedInteractionWorkbench(fixture.model)
        defer { host.window.orderOut(nil) }
        let title = try #require(await waitForField(
            in: host.view,
            identifier: "decomposition-title-\(first.id.uuidString)"
        ))
        #expect(await waitUntil {
            isFieldEditor(of: title, responder: host.window.firstResponder) || host.window.firstResponder === title
        })
    }

    @Test func intelligentTitleKeepsExistingFieldEditorFocus() async throws {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000941")!
        let fixture = try await WorkbenchInteractionFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates([
                    PlannerCandidate(
                        existingID: nil,
                        title: "打电话确认",
                        completionDescription: "拿到明确上门时间",
                        estimatedMinutes: 15
                    )
                ])
            ]),
            uuid: SequentialInteractionUUID([first]).next
        )
        await fixture.model.start()
        let host = hostedInteractionWorkbench(fixture.model)
        defer { host.window.orderOut(nil) }
        let firstTitle = try #require(await waitForField(
            in: host.view,
            identifier: "decomposition-title-\(first.uuidString)"
        ))
        #expect(host.window.makeFirstResponder(firstTitle))
        host.view.layoutSubtreeIfNeeded()
        if let identified = firstTitle as? DecompositionIdentifiedNSTextField {
            identified.requestsInitialFocus = true
            identified.attemptInitialFocusIfNeeded()
        }
        #expect(
            isFieldEditor(of: firstTitle, responder: host.window.firstResponder)
                || host.window.firstResponder === firstTitle
        )
    }

    @Test func initialFocusDoesNotStealExistingTextViewOrFieldEditor() async throws {
        _ = NSApplication.shared
        let window = InteractionTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.animationBehavior = .none
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        let existing = DecompositionIdentifiedNSTextField(frame: NSRect(x: 8, y: 60, width: 360, height: 24))
        existing.isEditable = true
        existing.isEnabled = true
        existing.stringValue = "已有输入"
        let incoming = DecompositionIdentifiedNSTextField(frame: NSRect(x: 8, y: 20, width: 360, height: 24))
        incoming.isEditable = true
        incoming.isEnabled = true
        incoming.requestsInitialFocus = true
        incoming.setAccessibilityIdentifier("incoming-title")
        root.addSubview(existing)
        root.addSubview(incoming)
        window.contentView = root
        window.makeKey()
        defer { window.orderOut(nil) }
        #expect(window.makeFirstResponder(existing))
        let editor = existing.currentEditor()
        incoming.attemptInitialFocusIfNeeded()
        #expect(window.firstResponder === existing || window.firstResponder === editor)

        let textView = NSTextView(frame: NSRect(x: 8, y: 80, width: 360, height: 24))
        textView.isEditable = true
        root.addSubview(textView)
        #expect(window.makeFirstResponder(textView))
        incoming.attemptInitialFocusIfNeeded()
        #expect(window.firstResponder === textView)
    }

    @Test func initialFocusDoesNotReclaimAfterUserMovesFirstResponderAway() async throws {
        _ = NSApplication.shared
        let window = InteractionTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 140),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.animationBehavior = .none
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 140))
        let field = DecompositionIdentifiedNSTextField(frame: NSRect(x: 8, y: 60, width: 360, height: 24))
        field.isEditable = true
        field.isEnabled = true
        field.requestsInitialFocus = true
        field.setAccessibilityIdentifier("decomposition-answer")
        let otherControl = DecompositionNSButton(frame: NSRect(x: 8, y: 20, width: 120, height: 24))
        otherControl.title = "其他"
        otherControl.bezelStyle = .rounded
        otherControl.intendedEnabled = true
        otherControl.isEnabled = true
        otherControl.refusesFirstResponder = false
        root.addSubview(field)
        root.addSubview(otherControl)
        window.contentView = root
        window.makeKey()
        defer { window.orderOut(nil) }

        field.attemptInitialFocusIfNeeded()
        #expect(window.firstResponder === field || window.firstResponder === field.currentEditor())

        #expect(window.makeFirstResponder(nil))
        field.attemptInitialFocusIfNeeded()
        #expect(
            window.firstResponder !== field
                && window.firstResponder !== field.currentEditor()
        )
        #expect(window.firstResponder === window || window.firstResponder == nil)

        #expect(window.makeFirstResponder(otherControl))
        field.attemptInitialFocusIfNeeded()
        #expect(window.firstResponder === otherControl)
    }

    @Test func singleLineFieldDoesNotOverwriteMarkedText() async throws {
        _ = NSApplication.shared
        let harness = SingleLineMarkedTextHarness()
        let hosting = NSHostingView(rootView: HostedSingleLineMarkedTextField(harness: harness))
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 48)
        let window = MarkedTextReportingWindow(
            contentRect: hosting.frame,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.animationBehavior = .none
        window.contentView = hosting
        window.makeKey()
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))
        defer { window.orderOut(nil) }

        let field = try #require(descendants(of: hosting, as: NSTextField.self).first {
            $0.accessibilityIdentifier() == "decomposition-single-line-marked"
        })
        #expect(field.stringValue == "原标题")
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(editor.hasMarkedText())
        field.stringValue = "原标题拼"
        #expect(field.stringValue == "原标题拼")

        harness.refreshToken += 1
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(field.stringValue == "原标题拼")
        #expect((field.currentEditor() as? NSTextView)?.hasMarkedText() == true)
        #expect(harness.text == "原标题")
    }

    @Test func refreshTimeKeepsUserAdjustedRows() async throws {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000951")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000952")!
        let fixture = try await WorkbenchInteractionFixture.make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates([
                    PlannerCandidate(
                        existingID: nil,
                        title: "打电话确认",
                        completionDescription: "拿到明确上门时间",
                        estimatedMinutes: 15
                    ),
                    PlannerCandidate(
                        existingID: nil,
                        title: "准备材料",
                        completionDescription: "把证件放一起",
                        estimatedMinutes: 30
                    )
                ])
            ]),
            uuid: SequentialInteractionUUID([first, second]).next
        )
        await fixture.model.start()
        fixture.model.setSelectedForCalendar(id: first, selected: true)
        fixture.model.setSelectedForCalendar(id: second, selected: true)
        fixture.model.advanceToSchedule()
        let originalFirst = try #require(fixture.model.draft.candidates[0].proposal)
        let originalSecond = try #require(fixture.model.draft.candidates[1].proposal)
        #expect(!fixture.model.draft.candidates[0].scheduleLockedByUser)

        let host = hostedInteractionWorkbench(fixture.model)
        defer { host.window.orderOut(nil) }
        host.view.layoutSubtreeIfNeeded()
        #expect(findButton(in: host.view, identifier: "decomposition-refresh-all-proposals") == nil)
        #expect(
            descendants(of: host.view, as: NSButton.self).contains { $0.title == "全部重新建议" } == false
        )

        fixture.model.updateProposalTime(id: first, instant: fixture.date(hour: 16, minute: 30))
        let locked = try #require(fixture.model.draft.candidates[0].proposal)
        #expect(fixture.model.draft.candidates[0].scheduleLockedByUser)
        #expect(locked != originalFirst)
        host.view.layoutSubtreeIfNeeded()
        #expect(await waitUntil {
            host.view.layoutSubtreeIfNeeded()
            return findButton(in: host.view, identifier: "decomposition-refresh-all-proposals") != nil
                || descendants(of: host.view, as: NSButton.self).contains { $0.title == "全部重新建议" }
        })

        let adjusted = descendants(of: host.view, as: NSTextField.self).first {
            $0.stringValue == "已调整"
        }
        #expect(adjusted != nil)
        #expect(adjusted?.font?.pointSize == 12)

        let refresh = try #require(
            findButton(in: host.view, identifier: "decomposition-refresh-proposals")
                ?? descendants(of: host.view, as: NSButton.self).first { $0.title == "重新建议时间" }
        )
        #expect(refresh.title == "重新建议时间")
        refresh.performClick(nil)
        #expect(await waitUntil {
            fixture.model.draft.candidates[0].proposal == locked
                && fixture.model.draft.candidates[1].proposal != originalSecond
        })
        #expect(fixture.model.draft.candidates[0].proposal == locked)
        #expect(fixture.model.draft.candidates[0].scheduleLockedByUser)
        #expect(fixture.model.draft.candidates[1].proposal != originalSecond)

        host.view.layoutSubtreeIfNeeded()
        let refreshAll = try #require(
            findButton(in: host.view, identifier: "decomposition-refresh-all-proposals")
                ?? descendants(of: host.view, as: NSButton.self).first { $0.title == "全部重新建议" }
        )
        #expect(refreshAll.title == "全部重新建议")
        let refreshAllHelp = [refreshAll.toolTip, refreshAll.accessibilityHelp()]
            .compactMap { $0 }
            .joined()
        #expect(refreshAllHelp.contains("覆盖"))
        #expect(refreshAllHelp.contains("人工调整"))
        refreshAll.performClick(nil)
        #expect(fixture.model.draft.candidates[0].proposal == locked)
        #expect(fixture.model.draft.candidates[0].scheduleLockedByUser)
        let overwrite = try #require(await waitForButtonTitled("覆盖并重新建议"))
        #expect(findButtonTitled("保留人工调整") != nil)
        overwrite.performClick(nil)
        #expect(await waitUntil {
            fixture.model.draft.candidates[0].proposal != locked
                && fixture.model.draft.candidates[0].scheduleLockedByUser == false
        })
        #expect(fixture.model.draft.candidates[0].proposal != locked)
        #expect(!fixture.model.draft.candidates[0].scheduleLockedByUser)
        #expect(fixture.model.draft.candidates[1].proposal != nil)
        #expect(await waitUntil {
            host.view.layoutSubtreeIfNeeded()
            return findButton(in: host.view, identifier: "decomposition-refresh-all-proposals") == nil
                && descendants(of: host.view, as: NSButton.self).contains { $0.title == "全部重新建议" } == false
        })
    }
}

private struct HostedInteractionWorkbench {
    let view: NSView
    let window: NSWindow
}

private final class SingleLineMarkedTextHarness: ObservableObject {
    @Published var text = "原标题"
    @Published var refreshToken = 0
}

private struct HostedSingleLineMarkedTextField: View {
    @ObservedObject var harness: SingleLineMarkedTextHarness

    var body: some View {
        VStack {
            DecompositionIdentifiedTextField(
                text: $harness.text,
                identifier: "decomposition-single-line-marked",
                accessibilityName: "行动标题"
            )
            .frame(width: 280, height: 24)
            Text(String(harness.refreshToken))
                .hidden()
        }
        .frame(width: 320, height: 48)
    }
}

private final class MarkedTextReportingFieldEditor: NSTextView {
    override func hasMarkedText() -> Bool { true }
}

private final class MarkedTextReportingWindow: NSWindow {
    private let markedEditor: MarkedTextReportingFieldEditor = {
        let editor = MarkedTextReportingFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        makeKey()
    }

    override func orderFront(_ sender: Any?) {}

    override func orderFrontRegardless() {}

    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        if object is NSTextField {
            markedEditor.isFieldEditor = true
            return markedEditor
        }
        return super.fieldEditor(createFlag, for: object)
    }
}

/// Never `orderFront` / `makeKeyAndOrderFront`: the first of those in this
/// helper makes SwiftPM's AppKit entry point return before remaining tests run.
/// See `SharedVerticalHostWindow` in NotesVerticalIntegrationTests.
private final class InteractionTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        makeKey()
    }

    override func orderFront(_ sender: Any?) {}

    override func orderFrontRegardless() {}
}

@MainActor
private func hostedInteractionWorkbench(
    _ model: DecompositionWorkbenchModel,
    onCancel: @escaping () -> Void = {},
    onCommitted: @escaping (DecompositionCommitResult) -> Void = { _ in }
) -> HostedInteractionWorkbench {
    _ = NSApplication.shared
    let root = DecompositionWorkbenchView(model: model, onCancel: onCancel, onCommitted: onCommitted)
        .frame(
            width: DecompositionWorkbenchMetrics.targetSize.width,
            height: DecompositionWorkbenchMetrics.targetSize.height
        )
    let hosting = NSHostingView(rootView: root)
    hosting.frame = CGRect(origin: .zero, size: DecompositionWorkbenchMetrics.targetSize)
    let window = InteractionTestWindow(
        contentRect: hosting.frame,
        styleMask: [],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.animationBehavior = .none
    window.contentView = hosting
    window.makeKey()
    hosting.layoutSubtreeIfNeeded()
    window.recalculateKeyViewLoop()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    return .init(view: hosting, window: window)
}

@MainActor
private struct WorkbenchInteractionFixture {
    let model: DecompositionWorkbenchModel
    let store: WorkspaceStore
    let noteID: NoteID
    let repository: InMemoryWorkspaceRepository

    static let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    static let now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai
        return calendar.date(from: DateComponents(year: 2026, month: 8, day: 22, hour: 8, minute: 0))!
    }()

    static func make(
        planner: any DecompositionPlanning,
        uuid: @escaping @Sendable () -> UUID = UUID.init
    ) async throws -> WorkbenchInteractionFixture {
        let calendar = makeEmptyState()
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: repository
        )
        await store.load()
        let blockID = BlockID()
        var note = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: now)
        note.document = .init(blocks: [
            .init(
                id: blockID,
                kind: .paragraph,
                inlineContent: .plain("预约牙医"),
                taskState: nil,
                indentLevel: 0
            )
        ])
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let persisted = try #require(store.state.notes[note.id])
        let snapshot = try DecompositionSourceCapture.capture(
            note: persisted,
            workspaceRevision: store.state.revision,
            selection: .text(
                anchor: .init(blockID: blockID, graphemeOffset: 0),
                focus: .init(blockID: blockID, graphemeOffset: 4),
                preferredColumn: nil,
                typingAttributes: .init(marks: [], linkURL: nil)
            )
        )
        let clockNow = now
        let model = DecompositionWorkbenchModel(
            snapshot: snapshot,
            planner: planner,
            store: store,
            clock: { clockNow },
            timeZone: shanghai,
            uuid: uuid
        )
        return .init(model: model, store: store, noteID: note.id, repository: repository)
    }

    static func readyToCommit() async throws -> WorkbenchInteractionFixture {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000931")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000932")!
        let fixture = try await make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.notNeeded),
                .candidates([
                    PlannerCandidate(
                        existingID: nil,
                        title: "打电话确认",
                        completionDescription: "拿到明确上门时间",
                        estimatedMinutes: 15
                    ),
                    PlannerCandidate(
                        existingID: nil,
                        title: "准备材料",
                        completionDescription: "把证件放一起",
                        estimatedMinutes: 30
                    )
                ])
            ]),
            uuid: SequentialInteractionUUID([first, second]).next
        )
        await fixture.model.start()
        return fixture
    }

    func date(hour: Int, minute: Int, dayOffset: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.shanghai
        let day = CalendarDate.localDay(containing: Self.now, in: Self.shanghai).addingDays(dayOffset)
        return calendar.date(from: DateComponents(
            year: day.year,
            month: day.month,
            day: day.day,
            hour: hour,
            minute: minute
        ))!
    }
}

private final class SequentialInteractionUUID: @unchecked Sendable {
    private var values: [UUID]
    init(_ values: [UUID]) { self.values = values }
    func next() -> UUID {
        values.isEmpty ? UUID() : values.removeFirst()
    }
}

private struct ImmediateInteractionSleeper: DecompositionSleeping {
    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
    }
}

private actor DualShotSplitPlanner: DecompositionPlanning {
    nonisolated var availability: DecompositionPlannerAvailability { .available }

    private var shots: [CheckedContinuation<[PlannerCandidate], Error>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var startedCount = 0

    func clarification(for request: ClarificationRequest) async throws -> ClarificationDecision {
        .notNeeded
    }

    func candidates(for request: CandidateRequest) async throws -> [PlannerCandidate] {
        [
            PlannerCandidate(
                existingID: nil,
                title: "打电话确认",
                completionDescription: "拿到明确上门时间",
                estimatedMinutes: 15
            ),
            PlannerCandidate(
                existingID: nil,
                title: "准备材料",
                completionDescription: "把证件放一起",
                estimatedMinutes: 30
            )
        ]
    }

    func splitCandidate(for request: SplitCandidateRequest) async throws -> [PlannerCandidate] {
        startedCount += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { shots.append($0) }
    }

    func waitUntilStarted(count: Int) async {
        while startedCount < count {
            await withCheckedContinuation { startWaiters.append($0) }
        }
    }

    func resumeOldest(_ items: [PlannerCandidate]) {
        guard !shots.isEmpty else { return }
        shots.removeFirst().resume(returning: items)
    }
}

private actor CancellableLongClarificationPlanner: DecompositionPlanning {
    nonisolated var availability: DecompositionPlannerAvailability { .available }

    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var startedCount = 0

    func clarification(for request: ClarificationRequest) async throws -> ClarificationDecision {
        startedCount += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        try await Task.sleep(for: .seconds(3_600))
        return .notNeeded
    }

    func candidates(for request: CandidateRequest) async throws -> [PlannerCandidate] {
        []
    }

    func splitCandidate(for request: SplitCandidateRequest) async throws -> [PlannerCandidate] {
        []
    }

    func waitUntilStarted(count: Int) async {
        while startedCount < count {
            await withCheckedContinuation { startWaiters.append($0) }
        }
    }
}

@MainActor
private func findButtonTitled(_ title: String) -> NSButton? {
    for window in NSApp.windows {
        if let content = window.contentView,
           let button = descendants(of: content, as: NSButton.self).first(where: { $0.title == title }) {
            return button
        }
        if let sheet = window.attachedSheet,
           let content = sheet.contentView,
           let button = descendants(of: content, as: NSButton.self).first(where: { $0.title == title }) {
            return button
        }
        for child in window.childWindows ?? [] {
            if let content = child.contentView,
               let button = descendants(of: content, as: NSButton.self).first(where: { $0.title == title }) {
                return button
            }
        }
    }
    return nil
}

@MainActor
private func waitForButtonTitled(_ title: String) async -> NSButton? {
    _ = await waitUntil {
        findButtonTitled(title) != nil
    }
    return findButtonTitled(title)
}

@MainActor
private func discardConfirmationMentionsUnsavedDraft() -> Bool {
    for window in NSApp.windows {
        let views: [NSView] = {
            var collected: [NSView] = []
            if let content = window.contentView {
                collected.append(contentsOf: descendants(of: content, as: NSView.self))
            }
            if let sheet = window.attachedSheet, let content = sheet.contentView {
                collected.append(contentsOf: descendants(of: content, as: NSView.self))
            }
            return collected
        }()
        for view in views {
            if let field = view as? NSTextField, field.stringValue.contains("这份草稿不会保存") {
                return true
            }
            if (view.accessibilityLabel() ?? "").contains("这份草稿不会保存") {
                return true
            }
            if (view.accessibilityValue() as? String)?.contains("这份草稿不会保存") == true {
                return true
            }
        }
        if window.title.contains("这份草稿不会保存") { return true }
    }
    return false
}

@MainActor
private func findButton(in root: NSView, identifier: String) -> NSButton? {
    descendants(of: root, as: NSButton.self).first {
        $0.accessibilityIdentifier() == identifier && $0.accessibilityRole() != .checkBox
    }
}

@MainActor
private func findCheckbox(in root: NSView, identifier: String) -> NSButton? {
    let identified = descendants(of: root, as: NSView.self).filter {
        $0.accessibilityIdentifier() == identifier
    }
    for view in identified {
        if let button = view as? NSButton, isCheckbox(button) {
            return button
        }
        if let button = descendants(of: view, as: NSButton.self).first(where: isCheckbox) {
            return button
        }
    }
    return descendants(of: root, as: NSButton.self).first { button in
        isCheckbox(button) && (
            button.accessibilityIdentifier() == identifier
                || button.superviews.contains { $0.accessibilityIdentifier() == identifier }
        )
    }
}

@MainActor
private func isCheckbox(_ button: NSButton) -> Bool {
    button.accessibilityRole() == .checkBox
}

private extension NSView {
    var superviews: [NSView] {
        var views: [NSView] = []
        var current = superview
        while let view = current {
            views.append(view)
            current = view.superview
        }
        return views
    }
}

@MainActor
private func calendarMembership(from checkbox: NSButton) -> String {
    if let value = checkbox.accessibilityValue() as? String {
        if value.contains("已加入") { return "已加入" }
        if value.contains("未加入") { return "未加入" }
        if value == "1" || value.lowercased() == "checked" || value.lowercased() == "on" {
            return "已加入"
        }
        if value == "0" || value.lowercased() == "unchecked" || value.lowercased() == "off" {
            return "未加入"
        }
    }
    if let number = checkbox.accessibilityValue() as? NSNumber {
        return number.boolValue ? "已加入" : "未加入"
    }
    if checkbox.state == .on { return "已加入" }
    if checkbox.state == .off { return "未加入" }
    return checkbox.integerValue == 1 ? "已加入" : "未加入"
}

@MainActor
private func waitForField(
    in root: NSView,
    identifier: String
) async -> NSTextField? {
    _ = await waitUntil {
        descendants(of: root, as: NSTextField.self).contains {
            $0.accessibilityIdentifier() == identifier
        }
    }
    return descendants(of: root, as: NSTextField.self).first {
        $0.accessibilityIdentifier() == identifier
    }
}

@MainActor
private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
    let own = (view as? T).map { [$0] } ?? []
    return own + view.subviews.flatMap { descendants(of: $0, as: type) }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
private func typeIntoFieldEditor(_ text: String, window: NSWindow) throws {
    let editor = try #require(fieldEditor(in: window))
    editor.selectAll(nil)
    editor.insertText(text, replacementRange: editor.selectedRange())
}

@MainActor
private func fieldEditor(in window: NSWindow) -> NSTextView? {
    (window.firstResponder as? NSTextView)
        ?? ((window.firstResponder as? NSTextField)?.currentEditor() as? NSTextView)
}

@MainActor
private func isFieldEditor(of field: NSTextField, responder: NSResponder?) -> Bool {
    responder === field.currentEditor() || (responder as? NSView)?.superview === field
}

@MainActor
private func isControl(_ control: NSView, responder: NSResponder?) -> Bool {
    responder === control
        || (responder as? NSView)?.superview === control
        || (control as? NSControl)?.currentEditor() === responder
}

@MainActor
private func tabUntil(
    in window: NSWindow,
    view: NSView,
    limit: Int = 48,
    target: String = "unspecified control",
    matches: (NSResponder?) -> Bool
) async throws {
    view.layoutSubtreeIfNeeded()
    window.recalculateKeyViewLoop()
    if matches(window.firstResponder) { return }
    for _ in 0..<limit {
        sendKey(tabKey(in: window), in: window)
        if matches(window.firstResponder) { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    let responder = window.firstResponder
    let identifier = (responder as? NSView)?.accessibilityIdentifier() ?? "nil"
    let next = (responder as? NSView)?.nextKeyView.map { String(describing: type(of: $0)) } ?? "nil"
    Issue.record(
        "tab did not reach \(target), firstResponder=\(String(describing: responder)) id=\(identifier) nextKeyView=\(next)"
    )
    throw KeyboardJourneyError.tabTargetMissing
}

private enum KeyboardJourneyError: Error {
    case tabTargetMissing
}

@MainActor
private func sendKey(_ event: NSEvent, in window: NSWindow) {
    if !window.isKeyWindow {
        window.makeKey()
    }
    if event.keyCode == 53 {
        _ = window.performKeyEquivalent(with: event)
    } else if event.keyCode == 36 {
        if window.firstResponder is NSTextView || window.firstResponder is NSTextField {
            window.firstResponder?.keyDown(with: event)
        } else {
            _ = window.performKeyEquivalent(with: event)
        }
    } else if let responder = window.firstResponder {
        responder.keyDown(with: event)
    } else {
        window.sendEvent(event)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
}

@MainActor
private func tabKey(in window: NSWindow, shift: Bool = false) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: shift ? .shift : [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "\t",
        charactersIgnoringModifiers: "\t",
        isARepeat: false,
        keyCode: 48
    )!
}

@MainActor
private func characterKey(_ character: String, in window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: character,
        charactersIgnoringModifiers: character,
        isARepeat: false,
        keyCode: 7
    )!
}

@MainActor
private func spaceKey(in window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: " ",
        charactersIgnoringModifiers: " ",
        isARepeat: false,
        keyCode: 49
    )!
}

@MainActor
private func returnKey(in window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "\r",
        charactersIgnoringModifiers: "\r",
        isARepeat: false,
        keyCode: 36
    )!
}

@MainActor
private func escapeKey(in window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}",
        isARepeat: false,
        keyCode: 53
    )!
}
