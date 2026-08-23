import AppKit
import CalendarDomain
import Foundation
import SwiftUI
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("DecompositionWorkbenchPresentationTests", .serialized)
@MainActor
struct DecompositionWorkbenchPresentationTests {
    @Test func workbenchExposesCoreControlsAndResultSummaryWithoutDuplicateAccessibilityElements() async throws {
        let fixture = try await WorkbenchPresentationFixture.splitWithScheduledActions()
        let host = hostedWorkbench(fixture.model, size: DecompositionWorkbenchMetrics.targetSize)
        defer { host.window.orderOut(nil) }

        let firstCandidateID = try #require(fixture.model.draft.candidates.first).id
        let labels = accessibilityLabels(in: host.view)
        #expect(labels.contains("理解"))
        #expect(labels.contains("拆开"))
        #expect(labels.contains("安排"))
        #expect(labels.contains("创建 3 个行动，并安排其中 2 个"))

        let identifiers = [
            "decomposition-stage-0",
            "decomposition-stage-1",
            "decomposition-stage-2",
            "decomposition-title-\(firstCandidateID.uuidString)",
            "decomposition-more-\(firstCandidateID.uuidString)",
            "decomposition-result-summary",
            "decomposition-advance",
        ]
        for identifier in identifiers {
            #expect(views(withIdentifier: identifier, in: host.view).count == 1)
        }

        let more = try #require(
            views(
                withIdentifier: "decomposition-more-\(firstCandidateID.uuidString)",
                in: host.view
            ).first as? NSButton
        )
        #expect(more.accessibilityLabel() == "更多操作")
        #expect(more.menu?.title == "更多操作")
        #expect(more.cell?.accessibilityIdentifier() != more.accessibilityIdentifier())
        #expect(more.cell?.isAccessibilityElement() != true)

        #expect(findButton(in: host.view, identifier: "decomposition-advance")?.title
            == "确认行动")
    }

    @Test func lightAndDarkConversationSurfacesStayWarmAndDistinctFromTheEditor() {
        #expect(CalendarTheme.light.conversationSurfaceHex == "#EBE3D6")
        #expect(CalendarTheme.dark.conversationSurfaceHex == "#191714")
        #expect(CalendarTheme.light.conversationSurfaceHex != CalendarTheme.light.elevatedSurfaceHex)
        #expect(CalendarTheme.dark.conversationSurfaceHex != CalendarTheme.dark.elevatedSurfaceHex)
        #expect(CalendarTheme.light.conversationSurfaceHex != CalendarTheme.light.canvasHex)
        #expect(CalendarTheme.dark.conversationSurfaceHex != CalendarTheme.dark.canvasHex)
        #expect(CalendarTheme.light.semanticHexValues.contains("#EBE3D6"))
        #expect(CalendarTheme.dark.semanticHexValues.contains("#191714"))
        #expect(!CalendarTheme.light.semanticHexValues.contains("#FFFFFF"))
        #expect(!CalendarTheme.dark.semanticHexValues.contains("#000000"))
    }

    @Test func wideLayoutKeepsConversationBesideActionsAndNarrowLayoutStacks() async throws {
        let wideFixture = try await WorkbenchPresentationFixture.understandWithQuestion()
        #expect(wideFixture.model.draft.stage == .understand)
        let wide = hostedWorkbench(wideFixture.model, size: CGSize(width: 960, height: 680))
        defer { wide.window.orderOut(nil) }
        let wideAnswer = try #require(findTextField(in: wide.view, identifier: "decomposition-answer"))
        let wideAdd = try #require(findButton(in: wide.view, identifier: "decomposition-add-candidate"))
        let wideAnswerFrame = wideAnswer.convert(wideAnswer.bounds, to: wide.view)
        let wideAddFrame = wideAdd.convert(wideAdd.bounds, to: wide.view)
        let wideHostWidth = wide.view.bounds.width
        #expect(wideAnswerFrame.maxX <= wideAddFrame.minX + 8)
        #expect(wideAnswerFrame.width < wideHostWidth * 0.5)
        #expect(wideAddFrame.minX > wideHostWidth * 0.33)

        let narrowFixture = try await WorkbenchPresentationFixture.understandWithQuestion()
        #expect(narrowFixture.model.draft.stage == .understand)
        let narrow = hostedWorkbench(narrowFixture.model, size: CGSize(width: 720, height: 560))
        defer { narrow.window.orderOut(nil) }
        let narrowAnswer = try #require(findTextField(in: narrow.view, identifier: "decomposition-answer"))
        let narrowAdd = try #require(findButton(in: narrow.view, identifier: "decomposition-add-candidate"))
        let narrowAnswerFrame = narrowAnswer.convert(narrowAnswer.bounds, to: narrow.view)
        let narrowAddFrame = narrowAdd.convert(narrowAdd.bounds, to: narrow.view)
        #expect(narrowAnswerFrame.maxY <= narrowAddFrame.minY + 8)
        #expect(
            max(narrowAnswerFrame.minX, narrowAddFrame.minX)
                < min(narrowAnswerFrame.maxX, narrowAddFrame.maxX)
        )
    }

    @Test func resultBarStaysFullWidthAndFixedHeight() async throws {
        let fixture = try await WorkbenchPresentationFixture.splitWithScheduledActions()
        let host = hostedWorkbench(fixture.model, size: DecompositionWorkbenchMetrics.targetSize)
        defer { host.window.orderOut(nil) }
        #expect(DecompositionWorkbenchMetrics.resultHeight == 64)
        let summary = try #require(findTextField(in: host.view, identifier: "decomposition-result-summary"))
        let advance = try #require(findButton(in: host.view, identifier: "decomposition-advance"))
        let summaryFrame = summary.convert(summary.bounds, to: host.view)
        let advanceFrame = advance.convert(advance.bounds, to: host.view)
        let band = DecompositionWorkbenchMetrics.resultHeight
        let hostBounds = host.view.bounds
        #expect(isInBottomBand(summaryFrame, hostBounds: hostBounds, height: band, tolerance: 2))
        #expect(isInBottomBand(advanceFrame, hostBounds: hostBounds, height: band, tolerance: 2))
        #expect(summaryFrame.maxX <= advanceFrame.minX + 2)
    }

    @Test func longChineseCompletionWrapsInsteadOfCollapsing() async throws {
        let fixture = try await WorkbenchPresentationFixture.splitWithScheduledActions()
        let long = String(repeating: "这是一段需要自动换行的中文完成说明，用来确认工作台不会把长句挤成一条。", count: 2)
        let firstID = try #require(fixture.model.draft.candidates.first).id
        fixture.model.updateCompletion(id: firstID, value: long)
        let identifier = "decomposition-completion-\(firstID.uuidString)"

        let narrow = hostedWorkbench(fixture.model, size: CGSize(width: 360, height: 680))
        defer { narrow.window.orderOut(nil) }
        let wide = hostedWorkbench(fixture.model, size: CGSize(width: 720, height: 680))
        defer { wide.window.orderOut(nil) }

        let narrowField = try uniqueMultilineTextField(identifier: identifier, in: narrow.view)
        let wideField = try uniqueMultilineTextField(identifier: identifier, in: wide.view)
        let narrowLineHeight = DecompositionMultilineNSTextField.lineHeight(for: narrowField.font)
        let wideLineHeight = DecompositionMultilineNSTextField.lineHeight(for: wideField.font)
        let narrowHeight = narrowField.sizeThatFits(NSSize(width: 280, height: 10_000)).height
        let wideHeight = wideField.sizeThatFits(NSSize(width: 640, height: 10_000)).height
        #expect(narrowHeight > wideHeight)
        expectHeightWithinVisibleLines(narrowHeight, lineHeight: narrowLineHeight)
        expectHeightWithinVisibleLines(wideHeight, lineHeight: wideLineHeight)
    }

    @Test func whitespaceOnlyEditsDisableRealAdvanceAndCommitButtons() async throws {
        let fixture = try await WorkbenchPresentationFixture.splitWithScheduledActions()
        let firstID = try #require(fixture.model.draft.candidates.first).id

        fixture.model.updateTitle(id: firstID, value: "   ")
        let whitespaceTitle = hostedWorkbench(fixture.model, size: DecompositionWorkbenchMetrics.targetSize)
        defer { whitespaceTitle.window.orderOut(nil) }
        let whitespaceTitleAdvance = try uniqueButton(
            identifier: "decomposition-advance",
            in: whitespaceTitle.view
        )
        #expect(whitespaceTitleAdvance.isEnabled == false)

        fixture.model.updateTitle(id: firstID, value: " 手改标题 ")
        fixture.model.updateCompletion(id: firstID, value: " \n ")
        let whitespaceCompletion = hostedWorkbench(fixture.model, size: DecompositionWorkbenchMetrics.targetSize)
        defer { whitespaceCompletion.window.orderOut(nil) }
        let whitespaceCompletionAdvance = try uniqueButton(
            identifier: "decomposition-advance",
            in: whitespaceCompletion.view
        )
        #expect(whitespaceCompletionAdvance.isEnabled == false)

        fixture.model.updateCompletion(id: firstID, value: " 完成说明 ")
        fixture.model.advanceToSchedule()
        fixture.model.updateTitle(id: firstID, value: "\t")
        let tabTitle = hostedWorkbench(fixture.model, size: DecompositionWorkbenchMetrics.targetSize)
        defer { tabTitle.window.orderOut(nil) }
        let tabTitleCommit = try uniqueButton(
            identifier: "decomposition-commit",
            in: tabTitle.view
        )
        #expect(tabTitleCommit.isEnabled == false)
    }

    @Test func blockingCopyStatesCountAndActionGuidance() throws {
        let sourceChanged = DecompositionWorkbenchCopy.blockingReason(.sourceChanged)
        #expect(sourceChanged.contains("关闭工作台，确认最新笔记后重新打开"))

        let noSelected = DecompositionWorkbenchCopy.blockingReason(.noSelectedActions)
        #expect(noSelected.contains("勾选"))
        #expect(noSelected.contains("行动"))

        let missingTitleOne = DecompositionWorkbenchCopy.blockingReason(.missingTitle(count: 1))
        let missingTitleTwo = DecompositionWorkbenchCopy.blockingReason(.missingTitle(count: 2))
        #expect(missingTitleOne.contains("1"))
        #expect(missingTitleOne.contains("标题"))
        #expect(missingTitleOne.contains("补全"))
        #expect(missingTitleTwo.contains("2"))
        #expect(missingTitleTwo.contains("标题"))
        #expect(missingTitleOne != missingTitleTwo)

        let missingCompletionOne = DecompositionWorkbenchCopy.blockingReason(.missingCompletion(count: 1))
        let missingCompletionThree = DecompositionWorkbenchCopy.blockingReason(.missingCompletion(count: 3))
        #expect(missingCompletionOne.contains("1"))
        #expect(missingCompletionOne.contains("完成说明"))
        #expect(missingCompletionOne.contains("补全"))
        #expect(missingCompletionThree.contains("3"))
        #expect(missingCompletionOne != missingCompletionThree)

        let missingProposalOne = DecompositionWorkbenchCopy.blockingReason(
            .missingCalendarProposal(count: 1)
        )
        let missingProposalTwo = DecompositionWorkbenchCopy.blockingReason(
            .missingCalendarProposal(count: 2)
        )
        #expect(missingProposalOne.contains("1"))
        #expect(missingProposalOne.contains("选择时间或取消加入日历"))
        #expect(missingProposalTwo.contains("2"))
        #expect(missingProposalTwo.contains("选择时间或取消加入日历"))
        #expect(missingProposalOne != missingProposalTwo)

        let calendarConflict = try #require(
            DecompositionWorkbenchCopy.recoverableError(.calendarConflict)
        )
        #expect(calendarConflict.contains("调整日期或时间"))
        #expect(calendarConflict.contains("取消加入日历"))

        let persistenceFailed = try #require(
            DecompositionWorkbenchCopy.recoverableError(.persistenceFailed)
        )
        #expect(persistenceFailed.contains("原笔记和日历没有被改动"))
        #expect(persistenceFailed.contains("重试"))
    }

    @Test func resultSummaryOrdersCommittingThenBlockingThenRecoverableThenCommitTitle() throws {
        let missingTitle = DecompositionWorkbenchBlockingReason.missingTitle(count: 1)
        #expect(
            DecompositionWorkbenchCopy.resultSummary(
                isCommitting: true,
                blockingReason: missingTitle,
                lastRecoverableError: .calendarConflict,
                created: 3,
                scheduled: 2
            ) == DecompositionWorkbenchCopy.committing
        )
        #expect(
            DecompositionWorkbenchCopy.resultSummary(
                isCommitting: false,
                blockingReason: missingTitle,
                lastRecoverableError: .calendarConflict,
                created: 3,
                scheduled: 2
            ) == DecompositionWorkbenchCopy.blockingReason(missingTitle)
        )
        let calendarConflictCopy = try #require(
            DecompositionWorkbenchCopy.recoverableError(.calendarConflict)
        )
        #expect(
            DecompositionWorkbenchCopy.resultSummary(
                isCommitting: false,
                blockingReason: nil,
                lastRecoverableError: .calendarConflict,
                created: 3,
                scheduled: 2
            ) == calendarConflictCopy
        )
        let planningFailedCopy = try #require(
            DecompositionWorkbenchCopy.recoverableError(.planningFailed)
        )
        #expect(
            DecompositionWorkbenchCopy.resultSummary(
                isCommitting: false,
                blockingReason: nil,
                lastRecoverableError: .planningFailed,
                created: 3,
                scheduled: 2
            ) == planningFailedCopy
        )
        #expect(
            DecompositionWorkbenchCopy.resultSummary(
                isCommitting: false,
                blockingReason: nil,
                lastRecoverableError: .requestCancelled,
                created: 3,
                scheduled: 2
            ) == "创建 3 个行动，并安排其中 2 个"
        )
        #expect(
            DecompositionWorkbenchCopy.resultSummary(
                isCommitting: false,
                blockingReason: nil,
                lastRecoverableError: nil,
                created: 3,
                scheduled: 2
            ) == "创建 3 个行动，并安排其中 2 个"
        )
        #expect(
            DecompositionWorkbenchCopy.resultSummary(
                isCommitting: false,
                blockingReason: .sourceChanged,
                lastRecoverableError: .sourceChanged,
                created: 3,
                scheduled: 2
            ) == DecompositionWorkbenchCopy.blockingReason(.sourceChanged)
        )
    }

    @Test func hostedResultSummaryShowsBlockingReasonsWithCountsAndActions() async throws {
        let fixture = try await WorkbenchPresentationFixture.splitWithScheduledActions()
        let firstID = try #require(fixture.model.draft.candidates.first).id
        let secondID = try #require(fixture.model.draft.candidates.dropFirst().first).id

        fixture.model.updateTitle(id: firstID, value: "   ")
        fixture.model.updateTitle(id: secondID, value: "")
        try expectHostedResultSummary(
            fixture.model,
            DecompositionWorkbenchCopy.blockingReason(.missingTitle(count: 2))
        )

        fixture.model.updateTitle(id: firstID, value: "手改标题")
        try expectHostedResultSummary(
            fixture.model,
            DecompositionWorkbenchCopy.blockingReason(.missingTitle(count: 1))
        )

        fixture.model.updateTitle(id: secondID, value: "第二项")
        fixture.model.updateCompletion(id: firstID, value: " \n ")
        try expectHostedResultSummary(
            fixture.model,
            DecompositionWorkbenchCopy.blockingReason(.missingCompletion(count: 1))
        )

        fixture.model.updateCompletion(id: firstID, value: "完成说明")
        for candidate in fixture.model.draft.candidates {
            fixture.model.setSelectedForCreation(id: candidate.id, selected: false)
        }
        try expectHostedResultSummary(
            fixture.model,
            DecompositionWorkbenchCopy.blockingReason(.noSelectedActions)
        )

        for candidate in fixture.model.draft.candidates {
            fixture.model.setSelectedForCreation(id: candidate.id, selected: true)
        }
        fixture.model.setSelectedForCalendar(id: firstID, selected: true)
        fixture.model.setSelectedForCalendar(id: secondID, selected: true)
        fixture.model.advanceToSchedule()
        fixture.model.setProposal(id: firstID, proposal: nil)
        fixture.model.setProposal(id: secondID, proposal: nil)
        try expectHostedResultSummary(
            fixture.model,
            DecompositionWorkbenchCopy.blockingReason(.missingCalendarProposal(count: 2))
        )
    }

    @Test func blockingReasonSelectsAndMarksFirstInvalidCandidate() async throws {
        let fixture = try await WorkbenchPresentationFixture.splitWithScheduledActions()
        let first = try #require(fixture.model.draft.candidates.first)
        let second = try #require(fixture.model.draft.candidates.dropFirst().first)
        let third = try #require(fixture.model.draft.candidates.last)
        #expect(fixture.model.draft.candidates.allSatisfy { $0.selectedForCreation })

        fixture.model.updateCompletion(id: second.id, value: "")
        fixture.model.updateTitle(id: third.id, value: "")
        #expect(fixture.model.firstBlockingCandidateID == second.id)

        let host = hostedWorkbench(
            fixture.model,
            size: DecompositionWorkbenchMetrics.targetSize,
            colorScheme: .light
        )
        defer { host.window.orderOut(nil) }

        #expect(await waitUntil {
            findTextField(
                in: host.view,
                identifier: "decomposition-completion-\(second.id.uuidString)"
            )?.isEditable == true
        })
        let completion = try uniqueMultilineTextField(
            identifier: "decomposition-completion-\(second.id.uuidString)",
            in: host.view
        )
        try expectInvalidField(
            completion,
            reason: "请补充完成标准",
            identifier: "decomposition-completion-error-\(second.id.uuidString)",
            in: host.view
        )
        #expect(
            findTextField(
                in: host.view,
                identifier: "decomposition-title-\(third.id.uuidString)"
            )?.isEditable != true
        )
        #expect(
            findTextField(
                in: host.view,
                identifier: "decomposition-title-error-\(third.id.uuidString)"
            ) == nil
        )
        #expect(
            findTextField(
                in: host.view,
                identifier: "decomposition-completion-error-\(first.id.uuidString)"
            ) == nil
        )
        let summary = try #require(
            findTextField(in: host.view, identifier: "decomposition-result-summary")
        )
        #expect(summary.stringValue.contains("完成说明") || summary.stringValue.contains("标题"))

        fixture.model.updateCompletion(id: second.id, value: "把证件和钥匙放一起")
        #expect(fixture.model.firstBlockingCandidateID == third.id)
        host.view.layoutSubtreeIfNeeded()
        #expect(await waitUntil {
            findTextField(
                in: host.view,
                identifier: "decomposition-title-\(third.id.uuidString)"
            )?.isEditable == true
                && findTextField(
                    in: host.view,
                    identifier: "decomposition-completion-error-\(second.id.uuidString)"
                ) == nil
        })

        let title = try uniqueEditableTextField(
            identifier: "decomposition-title-\(third.id.uuidString)",
            in: host.view
        )
        try expectInvalidField(
            title,
            reason: "请填写行动标题",
            identifier: "decomposition-title-error-\(third.id.uuidString)",
            in: host.view
        )
        #expect(
            findTextField(
                in: host.view,
                identifier: "decomposition-completion-error-\(second.id.uuidString)"
            ) == nil
        )
        let collapsedCompletion = findTextField(
            in: host.view,
            identifier: "decomposition-completion-\(second.id.uuidString)"
        )
        #expect(axInvalidValue(of: collapsedCompletion) != "true")
        #expect(collapsedCompletion?.isAccessibilityRequired() != true)

        let editor = try actionEditorSource()
        #expect(editor.contains("firstBlockingCandidateID"))
        #expect(editor.contains("theme.error"))
        #expect(editor.contains("请补充完成标准") || editor.contains("missingCompletionField"))
        #expect(!editor.contains("requestsInitialFocus: model.firstBlockingCandidateID"))
        #expect(!editor.contains("makeFirstResponder"))
        #expect(!editor.contains("LinearGradient"))
        #expect(!editor.contains("Capsule()"))
    }

    @Test func sourceChangedCopyAndModelGatesAreWiredFromViewSource() async throws {
        let fixture = try await WorkbenchPresentationFixture.splitWithScheduledActions(
            snapshotRevisionOffset: -1
        )
        fixture.model.advanceToSchedule()
        let result = await fixture.model.commit()
        #expect(result == .sourceChanged)
        #expect(fixture.model.advanceBlockingReason == .sourceChanged)
        #expect(fixture.model.commitBlockingReason == .sourceChanged)
        #expect(!fixture.model.canAdvance)
        #expect(!fixture.model.canCommit)

        let host = hostedWorkbench(fixture.model, size: DecompositionWorkbenchMetrics.targetSize)
        defer { host.window.orderOut(nil) }
        let summary = try #require(
            findTextField(in: host.view, identifier: "decomposition-result-summary")
        )
        #expect(summary.stringValue == DecompositionWorkbenchCopy.blockingReason(.sourceChanged))
        #expect(summary.stringValue.contains("关闭工作台，确认最新笔记后重新打开"))
        let advance = try uniqueButton(identifier: "decomposition-advance", in: host.view)
        #expect(advance.isEnabled == false)

        let viewSource = try workbenchViewSource()
        #expect(viewSource.contains("enabled: model.canAdvance && !model.isCommitting"))
        #expect(viewSource.contains("enabled: model.canCommit && !model.isCommitting"))
        #expect(viewSource.contains("model.draft.stage == .schedule, model.canCommit"))
        #expect(!viewSource.contains("private var canAdvance"))
        #expect(!viewSource.contains("private var canCommit"))

        let paneSource = try workbenchConversationSource()
        #expect(paneSource.contains("manualBanner(for: reason)"))
        #expect(paneSource.contains(".manual(let reason)"))
    }

    @Test func loadingStateExposesStopAndAvoidsPersonaCopy() async throws {
        let planner = SleepingWorkbenchPlanner()
        let fixture = try await WorkbenchPresentationFixture.make(planner: planner)
        let starting = Task { await fixture.model.start() }
        #expect(await waitUntil {
            if case .running(_, .clarification) = fixture.model.requestState { return true }
            return false
        })
        let host = hostedWorkbench(fixture.model, size: DecompositionWorkbenchMetrics.targetSize)
        defer { host.window.orderOut(nil) }
        let labels = accessibilityLabels(in: host.view)
        #expect(labels.contains("正在整理…"))
        #expect(labels.contains("停止"))
        #expect(!labels.contains { $0.contains("思考") || $0.contains("%") || $0.contains("马上就好") })
        let stop = try #require(findButton(in: host.view, identifier: "decomposition-stop"))
        #expect(stop.accessibilityLabel() == "停止")
        #expect(stop.accessibilityHelp() == "停止这次整理")
        fixture.model.cancelRequest()
        await starting.value
    }

    @Test func manualModeStatesTheHonestUnavailableReasonWithoutFakeIntelligence() async throws {
        let fixture = try await WorkbenchPresentationFixture.make(
            planner: UnavailableDecompositionPlanner(reason: .systemVersionUnsupported)
        )
        await fixture.model.start()
        let host = hostedWorkbench(fixture.model, size: DecompositionWorkbenchMetrics.targetSize)
        defer { host.window.orderOut(nil) }
        let expected = DecompositionWorkbenchCopy.manualBanner(for: .systemVersionUnsupported)
        let labels = accessibilityLabels(in: host.view)
        #expect(labels.contains(expected))
        #expect(expected.contains("系统版本"))
        #expect(!expected.contains("当前设备暂时不能"))
        #expect(!labels.contains { $0.contains("当前设备暂时不能") })
        #expect(!labels.contains { $0.contains("智能建议") || $0.contains("AI 已拆好") })
        let banner = try #require(
            findTextField(in: host.view, identifier: "decomposition-manual-banner")
        )
        #expect(banner.stringValue == expected)
        #expect(fixture.model.draft.mode == .manual(reason: .systemVersionUnsupported))
        #expect(fixture.model.draft.candidates.count == 1)
        #expect(fixture.model.draft.candidates[0].title.isEmpty)
        #expect(fixture.model.draft.candidates[0].completionDescription.isEmpty)
        let firstID = try #require(fixture.model.draft.candidates.first).id
        let titleField = try uniqueEditableTextField(
            identifier: "decomposition-title-\(firstID.uuidString)",
            in: host.view
        )
        #expect(titleField.isEditable)
        #expect(titleField.stringValue.isEmpty)
    }

    @Test func answerHasVisibleContinueAndReturnUsesSameSubmission() async throws {
        let fixture = try await WorkbenchPresentationFixture.understandWithQuestion()
        let host = hostedWorkbench(fixture.model, size: DecompositionWorkbenchMetrics.targetSize)
        defer { host.window.orderOut(nil) }
        let button = try uniqueButton(identifier: "decomposition-answer-continue", in: host.view)
        #expect(button.title == "继续")
        #expect(!button.isEnabled)
        fixture.model.updateAnswer("下周前完成")
        host.view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))
        let enabledButton = try uniqueButton(identifier: "decomposition-answer-continue", in: host.view)
        #expect(enabledButton.isEnabled)

        let paneSource = try workbenchConversationSource()
        #expect(paneSource.contains("private func submitAnswer()"))
        #expect(paneSource.contains("onSubmit: {"))
        #expect(paneSource.contains("submitAnswer()"))
        #expect(paneSource.contains("identifier: \"decomposition-answer-continue\""))
        #expect(paneSource.contains("DecompositionWorkbenchCopy.continueAnswer"))
        #expect(paneSource.contains("onSubmit: { submitAnswer() }"))
        let submitOccurrences = paneSource.components(separatedBy: "submitAnswer()").count - 1
        #expect(submitOccurrences >= 3)
    }

    @Test func sourceShowsWholeOrSelectionScopeAndCanExpand() async throws {
        let longChinese = (1...12).map { index in
            "第\(index)段需要展开才能读完的中文来源，确认工作台不会把长笔记藏起来，并且内部可以滚动。"
        }.joined(separator: "\n") + "\n第八段完整长中文结尾标记。"
        let planner = UnavailableDecompositionPlanner(reason: .modelFailure)

        let whole = try await WorkbenchPresentationFixture.make(
            planner: planner,
            sourceText: longChinese,
            wholeNote: true
        )
        #expect(whole.model.draft.source.selectedRange == nil)
        #expect(whole.model.draft.source.normalizedText.contains("完整长中文结尾标记"))

        let selected = try await WorkbenchPresentationFixture.make(
            planner: planner,
            sourceText: longChinese,
            wholeNote: false
        )
        let selectedRange = try #require(selected.model.draft.source.selectedRange)
        #expect(selectedRange.lowerGraphemeOffset == 0)
        #expect(selectedRange.upperGraphemeOffset == 4)
        #expect(selected.model.draft.source.normalizedText.count == 4)
        #expect(selected.model.draft.source.normalizedText != longChinese)

        let selectedHost = hostedWorkbench(
            selected.model,
            size: DecompositionWorkbenchMetrics.targetSize
        )
        defer { selectedHost.window.orderOut(nil) }
        let selectedLabels = accessibilityLabels(in: selectedHost.view)
        #expect(selectedLabels.contains("所选文字"))
        #expect(!selectedLabels.contains("整篇笔记"))
        #expect(
            findButton(in: selectedHost.view, identifier: "decomposition-source-toggle")?.title
                == "展开来源"
        )

        let wholeHost = hostedWorkbench(
            whole.model,
            size: DecompositionWorkbenchMetrics.targetSize,
            colorScheme: .light
        )
        defer { wholeHost.window.orderOut(nil) }
        let wholeLabels = accessibilityLabels(in: wholeHost.view)
        #expect(wholeLabels.contains("整篇笔记"))
        #expect(!wholeLabels.contains("所选文字"))
        let wholeToggle = try uniqueButton(
            identifier: "decomposition-source-toggle",
            in: wholeHost.view
        )
        #expect(wholeToggle.title == "展开来源")

        let collapsedField = try uniqueSourceTextField(in: wholeHost.view)
        #expect(collapsedField.maximumNumberOfLines == 6)
        #expect(collapsedField.stringValue.contains("完整长中文结尾标记"))
        #expect(collapsedField.accessibilityLabel()?.contains("完整长中文结尾标记") == true)
        #expect(wholeLabels.contains { $0.contains("完整长中文结尾标记") })
        expectSourceTextColor(collapsedField, matches: CalendarTheme.light)
        let collapsedHeight = collapsedField.bounds.height
        let collapsedIntrinsic = collapsedField.intrinsicContentSize.height
        let collapsedDocumentHeight = enclosingScrollView(from: collapsedField)?
            .documentView?.bounds.height ?? 0

        wholeToggle.performClick(nil)
        wholeHost.view.layoutSubtreeIfNeeded()
        #expect(await waitUntil {
            findTextField(in: wholeHost.view, identifier: "decomposition-source-text")?
                .maximumNumberOfLines == 0
        })
        let expandedField = try uniqueSourceTextField(in: wholeHost.view)
        #expect(expandedField.maximumNumberOfLines == 0)
        #expect(expandedField.stringValue.contains("完整长中文结尾标记"))
        #expect(expandedField.accessibilityLabel()?.contains(longChinese) == true)
        #expect(
            findButton(in: wholeHost.view, identifier: "decomposition-source-toggle")?.title
                == "收起来源"
        )
        #expect(await waitUntil {
            guard let field = findTextField(
                in: wholeHost.view,
                identifier: "decomposition-source-text"
            ) else { return false }
            let documentHeight = enclosingScrollView(from: field)?.documentView?.bounds.height ?? 0
            return field.bounds.height > collapsedHeight + 1
                || field.intrinsicContentSize.height > collapsedIntrinsic + 1
                || documentHeight > collapsedDocumentHeight + 1
        })

        let expandedToggle = try uniqueButton(
            identifier: "decomposition-source-toggle",
            in: wholeHost.view
        )
        expandedToggle.performClick(nil)
        wholeHost.view.layoutSubtreeIfNeeded()
        #expect(await waitUntil {
            findTextField(in: wholeHost.view, identifier: "decomposition-source-text")?
                .maximumNumberOfLines == 6
        })
        #expect(try uniqueSourceTextField(in: wholeHost.view).maximumNumberOfLines == 6)
        #expect(
            findButton(in: wholeHost.view, identifier: "decomposition-source-toggle")?.title
                == "展开来源"
        )

        let darkHost = hostedWorkbench(
            whole.model,
            size: DecompositionWorkbenchMetrics.targetSize,
            colorScheme: .dark
        )
        defer { darkHost.window.orderOut(nil) }
        expectSourceTextColor(
            try uniqueSourceTextField(in: darkHost.view),
            matches: CalendarTheme.dark
        )

        let narrow = hostedWorkbench(whole.model, size: CGSize(width: 720, height: 560))
        defer { narrow.window.orderOut(nil) }
        let narrowToggle = try uniqueButton(
            identifier: "decomposition-source-toggle",
            in: narrow.view
        )
        narrowToggle.performClick(nil)
        narrow.view.layoutSubtreeIfNeeded()
        #expect(await waitUntil {
            findButton(in: narrow.view, identifier: "decomposition-source-toggle")?.title
                == "收起来源"
        })
        let expandedNarrowToggle = try uniqueButton(
            identifier: "decomposition-source-toggle",
            in: narrow.view
        )
        let paneHeight = stackedSourcePaneHeight(from: expandedNarrowToggle)
        #expect(paneHeight >= 168)
        #expect(paneHeight <= 220 + 8)
        #expect(await waitUntil {
            guard let scroll = enclosingScrollView(from: expandedNarrowToggle) else { return false }
            let documentHeight = scroll.documentView?.bounds.height ?? 0
            return documentHeight > scroll.contentView.bounds.height + 8
        })
        let scroll = try #require(enclosingScrollView(from: expandedNarrowToggle))
        #expect(scroll.documentView != nil)
        #expect((scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height + 8)
    }

    @Test func manualBannerCopyDistinguishesEveryUnavailableReason() throws {
        let reasons: [ManualDecompositionReason] = [
            .systemVersionUnsupported,
            .deviceNotEligible,
            .appleIntelligenceNotEnabled,
            .modelNotReady,
            .localeUnsupported,
            .timedOut,
            .repeatedInvalidOutput,
            .modelFailure
        ]
        let expectedFragments: [ManualDecompositionReason: String] = [
            .systemVersionUnsupported: "系统版本",
            .deviceNotEligible: "设备不支持",
            .appleIntelligenceNotEnabled: "Apple 智能",
            .modelNotReady: "准备中",
            .localeUnsupported: "当前语言",
            .timedOut: "超时",
            .repeatedInvalidOutput: "不可靠",
            .modelFailure: "失败了"
        ]
        var banners: [String] = []
        for reason in reasons {
            let banner = DecompositionWorkbenchCopy.manualBanner(for: reason)
            #expect(banner.contains("仍可手动添加和安排行动"))
            #expect(!banner.contains("当前设备暂时不能"))
            #expect(banner.contains(try #require(expectedFragments[reason])))
            banners.append(banner)
        }
        #expect(Set(banners).count == reasons.count)
    }

    @Test func workbenchSourceKeepsOperateTypographyMotionAndNoDecorativeChrome() throws {
        let sources = try workbenchSources()
        #expect(sources.contains("ViewThatFits(in: .horizontal)"))
        #expect(sources.contains("conversationSurface"))
        #expect(sources.contains("CalendarMotionPolicy(reduceMotion:"))
        #expect(sources.contains("Font.system(size: 16"))
        #expect(sources.contains("Font.system(size: 15"))
        #expect(sources.contains("Font.system(size: 14"))
        #expect(sources.contains("Font.system(size: 12"))
        #expect(!sources.contains("LinearGradient"))
        #expect(!sources.contains(".largeTitle"))
        #expect(!sources.contains(".title2"))
        #expect(!sources.contains(".title3"))
        #expect(!sources.contains("Font.system(size: 18"))
        #expect(!sources.contains("Font.system(size: 22"))
        #expect(!sources.contains("Font.system(size: 28"))
        #expect(!sources.contains("Capsule()"))
        #expect(CalendarMotionPolicy(reduceMotion: true).overlayAnimation == nil)
        #expect(CalendarMotionPolicy(reduceMotion: true).snapAnimation == nil)
    }

    @Test func actionRowsExposeANarrowDragHandleAndDropOntoCandidateIDs() async throws {
        let fixture = try await WorkbenchPresentationFixture.splitWithScheduledActions()
        let host = hostedWorkbench(fixture.model, size: DecompositionWorkbenchMetrics.targetSize)
        defer { host.window.orderOut(nil) }
        let firstID = try #require(fixture.model.draft.candidates.first).id
        let handleID = "decomposition-drag-handle-\(firstID.uuidString)"
        let titleID = "decomposition-title-\(firstID.uuidString)"
        let handles = views(withIdentifier: handleID, in: host.view)
        #expect(handles.count == 1)
        let handle = try #require(handles.first)
        let title = try uniqueEditableTextField(identifier: titleID, in: host.view)
        let handleFrame = handle.convert(handle.bounds, to: host.view)
        let titleFrame = title.convert(title.bounds, to: host.view)
        #expect(handleFrame.width < titleFrame.width)
        #expect(handleFrame.maxX <= titleFrame.minX + 2)
        #expect(handle.isAccessibilityElement() != true)
        #expect(handle.accessibilityLabel()?.isEmpty != false)

        let editor = try actionEditorSource()
        #expect(editor.contains(".draggable(candidate.id.uuidString)"))
        #expect(editor.contains(".dropDestination(for: String.self)"))
        #expect(editor.contains("model.moveCandidate(id: draggedID, toPositionOf: targetID)"))
        #expect(editor.contains("model.moveCandidate(id: id, toPositionOf:"))
        #expect(editor.contains("!model.isCommitting"))
        #expect(editor.contains(".accessibilityHidden(true)"))
        #expect(!editor.contains("fromOffsets"))
        #expect(!editor.contains("toOffset"))
        #expect(!editor.contains(".onDrag("))
    }

    @Test func commitButtonCopyTracksCreationAndScheduleCounts() async throws {
        let fixture = try await WorkbenchPresentationFixture.splitWithScheduledActions()
        fixture.model.returnToStage(.split)
        let unscheduled = hostedWorkbench(fixture.model, size: DecompositionWorkbenchMetrics.targetSize)
        defer { unscheduled.window.orderOut(nil) }
        #expect(findButton(in: unscheduled.view, identifier: "decomposition-advance")?.title == "确认行动")

        let first = try #require(fixture.model.draft.candidates.first)
        let second = try #require(fixture.model.draft.candidates.dropFirst().first)
        fixture.model.setSelectedForCalendar(id: first.id, selected: false)
        fixture.model.setSelectedForCalendar(id: second.id, selected: false)
        fixture.model.advanceToSchedule()
        let noneScheduled = hostedWorkbench(fixture.model, size: DecompositionWorkbenchMetrics.targetSize)
        defer { noneScheduled.window.orderOut(nil) }
        #expect(findButton(in: noneScheduled.view, identifier: "decomposition-commit")?.title
            == "创建 3 个行动，暂不安排")

        for candidate in fixture.model.draft.candidates {
            fixture.model.setSelectedForCreation(id: candidate.id, selected: false)
        }
        let empty = hostedWorkbench(fixture.model, size: DecompositionWorkbenchMetrics.targetSize)
        defer { empty.window.orderOut(nil) }
        let emptyButton = try #require(findButton(in: empty.view, identifier: "decomposition-commit"))
        #expect(emptyButton.title == "至少保留一个行动")
        #expect(emptyButton.isEnabled == false)
    }

    @Test func identifiedTextFieldsKeepTheSystemFocusRing() async throws {
        let questionFixture = try await WorkbenchPresentationFixture.understandWithQuestion()
        let questionHost = hostedWorkbench(
            questionFixture.model,
            size: DecompositionWorkbenchMetrics.targetSize
        )
        defer { questionHost.window.orderOut(nil) }
        let answer = try uniqueEditableTextField(
            identifier: "decomposition-answer",
            in: questionHost.view
        )
        #expect(answer.focusRingType != .none)
        #expect(answer.cell?.focusRingType != NSFocusRingType.none)

        let splitFixture = try await WorkbenchPresentationFixture.splitWithScheduledActions()
        let splitHost = hostedWorkbench(
            splitFixture.model,
            size: DecompositionWorkbenchMetrics.targetSize
        )
        defer { splitHost.window.orderOut(nil) }
        let firstID = try #require(splitFixture.model.draft.candidates.first).id
        let completion = try uniqueMultilineTextField(
            identifier: "decomposition-completion-\(firstID.uuidString)",
            in: splitHost.view
        )
        #expect(completion.focusRingType != .none)
        #expect(completion.cell?.focusRingType != NSFocusRingType.none)

        let sources = try workbenchSources()
        #expect(!sources.contains("focusRingType = .none"))
        #expect(!sources.contains("focusRingType=.none"))
    }

    @Test func stageButtonsExposeCurrentCompletedAndUnreachedState() async throws {
        let understandFixture = try await WorkbenchPresentationFixture.understandWithQuestion()
        #expect(understandFixture.model.draft.stage == .understand)
        let understandHost = hostedWorkbench(
            understandFixture.model,
            size: DecompositionWorkbenchMetrics.targetSize
        )
        defer { understandHost.window.orderOut(nil) }
        try expectStageButtons(in: understandHost.view, current: .understand)

        let splitFixture = try await WorkbenchPresentationFixture.splitWithScheduledActions()
        #expect(splitFixture.model.draft.stage == .split)
        let splitHost = hostedWorkbench(
            splitFixture.model,
            size: DecompositionWorkbenchMetrics.targetSize
        )
        defer { splitHost.window.orderOut(nil) }
        try expectStageButtons(in: splitHost.view, current: .split)

        splitFixture.model.advanceToSchedule()
        #expect(splitFixture.model.draft.stage == .schedule)
        let scheduleHost = hostedWorkbench(
            splitFixture.model,
            size: DecompositionWorkbenchMetrics.targetSize
        )
        defer { scheduleHost.window.orderOut(nil) }
        try expectStageButtons(in: scheduleHost.view, current: .schedule)

        let close = try uniqueButton(identifier: "decomposition-close", in: scheduleHost.view)
        #expect(close.isEnabled == true)
        #expect((close.accessibilityValue() as? String)?.contains("步骤") != true)
        #expect(close.isAccessibilitySelected() != true)

        let advance = try uniqueButton(identifier: "decomposition-advance", in: splitHost.view)
        #expect(advance.isAccessibilitySelected() != true)

        let add = try uniqueButton(identifier: "decomposition-add-candidate", in: splitHost.view)
        #expect(add.isAccessibilitySelected() != true)

        let sources = try workbenchSources()
        #expect(sources.contains("var selected: Bool? = nil"))
        #expect(sources.contains("if let selected"))
    }

    @Test func scheduleCalendarToggleUsesNativeCheckboxWithActionTitleAndMembershipState() async throws {
        let fixture = try await WorkbenchPresentationFixture.splitWithScheduledActions()
        fixture.model.advanceToSchedule()
        let first = try #require(fixture.model.draft.candidates.first)
        let third = try #require(fixture.model.draft.candidates.last)
        #expect(first.selectedForCalendar)
        #expect(!third.selectedForCalendar)

        let host = hostedWorkbench(fixture.model, size: DecompositionWorkbenchMetrics.targetSize)
        defer { host.window.orderOut(nil) }

        let joined = try uniqueCheckbox(
            identifier: "decomposition-calendar-\(first.id.uuidString)",
            in: host.view
        )
        let idle = try uniqueCheckbox(
            identifier: "decomposition-calendar-\(third.id.uuidString)",
            in: host.view
        )
        #expect(joined.accessibilityRole() == .checkBox)
        #expect(idle.accessibilityRole() == .checkBox)
        #expect(joined.title == DecompositionWorkbenchCopy.joinCalendar)
        #expect(idle.title == DecompositionWorkbenchCopy.joinCalendar)
        let joinedLabel = joined.accessibilityLabel() ?? ""
        let idleLabel = idle.accessibilityLabel() ?? ""
        #expect(joinedLabel.contains(first.title))
        #expect(idleLabel.contains(third.title))
        #expect((joined.accessibilityValue() as? NSNumber)?.intValue == 1)
        #expect((idle.accessibilityValue() as? NSNumber)?.intValue == 0)
        #expect(joined.isAccessibilityEnabled() == true)
        #expect(idle.isAccessibilityEnabled() == true)
    }

    // 折叠行动行的 SwiftUI 合成 AX 节点在 NSHostingView 单测中不可枚举。
    // 这里直接校验完整中文 copy 与源码契约；最终 VoiceOver 听感是产品实操边界。
    @Test func actionCreationCheckboxIncludesTitleAndCollapsedRowCopyIsVoiceOverProductBoundary() async throws {
        let fixture = try await WorkbenchPresentationFixture.splitWithScheduledActions()
        let first = try #require(fixture.model.draft.candidates.first)
        let second = try #require(fixture.model.draft.candidates.dropFirst().first)
        let longCompletion = "把证件和钥匙放一起，并带上纸质合同和门禁卡"
        fixture.model.updateCompletion(id: second.id, value: longCompletion)

        let host = hostedWorkbench(fixture.model, size: DecompositionWorkbenchMetrics.targetSize)
        defer { host.window.orderOut(nil) }

        let creationBoxes = checkboxes(in: host.view).filter { box in
            (box.accessibilityLabel() ?? "").contains(DecompositionWorkbenchCopy.keepAction)
        }
        #expect(creationBoxes.count == fixture.model.draft.candidates.count)
        let firstBox = try #require(creationBoxes.first {
            ($0.accessibilityLabel() ?? "").contains(first.title)
        })
        let secondBox = try #require(creationBoxes.first {
            ($0.accessibilityLabel() ?? "").contains(second.title)
        })
        let firstBoxLabel = firstBox.accessibilityLabel() ?? ""
        let secondBoxLabel = secondBox.accessibilityLabel() ?? ""
        #expect(firstBoxLabel.contains(first.title))
        #expect(secondBoxLabel.contains(second.title))
        #expect(firstBox.title == DecompositionWorkbenchCopy.createAction)
        #expect(secondBox.title == DecompositionWorkbenchCopy.createAction)
        #expect(firstBox.accessibilityRole() == .checkBox)
        #expect(secondBox.accessibilityRole() == .checkBox)
        #expect((firstBox.accessibilityValue() as? NSNumber)?.intValue == 1)
        #expect((secondBox.accessibilityValue() as? NSNumber)?.intValue == 1)

        let collapsedLabel = DecompositionWorkbenchCopy.collapsedActionAccessibilityLabel(
            title: second.title,
            completion: longCompletion,
            minutes: second.estimatedDuration.rawValue
        )
        #expect(collapsedLabel == "\(second.title)，\(longCompletion)，预计 \(second.estimatedDuration.rawValue) 分钟")
        #expect(
            DecompositionWorkbenchCopy.collapsedActionAccessibilityLabel(
                title: "",
                completion: "",
                minutes: 15
            ) == "未命名行动，还没有完成说明，预计 15 分钟"
        )

        let sources = try workbenchSources()
        #expect(sources.contains(".accessibilityElement(children: .ignore)"))
        #expect(sources.contains(".accessibilityLabel("))
        #expect(sources.contains("DecompositionWorkbenchCopy.collapsedActionAccessibilityLabel("))
        #expect(sources.contains(".accessibilityHint(\"展开后可微调行动标题、完成说明和预计时长\")"))
        #expect(sources.contains(".accessibilityAddTraits(.isButton)"))
    }

    @Test func actionRowsExposeClearCreationAndGroupedSecondaryControls() async throws {
        let intelligent = try await WorkbenchPresentationFixture.splitWithScheduledActions()
        let first = try #require(intelligent.model.draft.candidates.first)
        let second = try #require(intelligent.model.draft.candidates.dropFirst().first)
        let host = hostedWorkbench(
            intelligent.model,
            size: DecompositionWorkbenchMetrics.targetSize
        )
        defer { host.window.orderOut(nil) }

        let creationBoxes = checkboxes(in: host.view).filter { box in
            (box.accessibilityLabel() ?? "").contains(first.title)
                || (box.accessibilityLabel() ?? "").contains(second.title)
        }
        let firstBox = try #require(creationBoxes.first {
            ($0.accessibilityLabel() ?? "").contains(first.title)
        })
        let secondBox = try #require(creationBoxes.first {
            ($0.accessibilityLabel() ?? "").contains(second.title)
        })
        #expect(firstBox.title == "创建")
        #expect(secondBox.title == "创建")
        #expect((firstBox.accessibilityLabel() ?? "").contains(first.title))
        #expect((secondBox.accessibilityLabel() ?? "").contains(second.title))

        let completion = try uniqueMultilineTextField(
            identifier: "decomposition-completion-\(first.id.uuidString)",
            in: host.view
        )
        #expect(completion.placeholderString == "做到什么算完成？")
        #expect(completion.accessibilityLabel() == "完成说明")

        let title = try uniqueEditableTextField(
            identifier: "decomposition-title-\(first.id.uuidString)",
            in: host.view
        )
        let more = try uniqueButton(
            identifier: "decomposition-more-\(first.id.uuidString)",
            in: host.view
        )
        let moveUp = try uniqueButton(
            identifier: "decomposition-move-up-\(first.id.uuidString)",
            in: host.view
        )
        let moveDown = try uniqueButton(
            identifier: "decomposition-move-down-\(first.id.uuidString)",
            in: host.view
        )
        let titleFrame = title.convert(title.bounds, to: host.view)
        let completionFrame = completion.convert(completion.bounds, to: host.view)
        let moreFrame = more.convert(more.bounds, to: host.view)
        let moveUpFrame = moveUp.convert(moveUp.bounds, to: host.view)
        #expect(titleFrame.maxY <= completionFrame.minY + 8)
        #expect(completionFrame.maxY <= moreFrame.minY + 8)
        #expect(abs(moreFrame.midY - moveUpFrame.midY) < 12)
        #expect(moveDown.convert(moveDown.bounds, to: host.view).minX >= moveUpFrame.maxX - 2)

        let destructiveTitles = (more.menu?.items ?? []).compactMap { item -> String? in
            let title = item.attributedTitle?.string ?? item.title
            return item.isEnabled && (item.attributedTitle != nil || title == "删除") ? title : nil
        }.filter { $0 == "删除" }
        #expect(destructiveTitles.count == 1)
        let deleteButtons = descendants(of: host.view, as: NSButton.self).filter {
            $0.title == "删除" && $0.accessibilityRole() != .checkBox
        }
        #expect(deleteButtons.isEmpty)

        let split = try uniqueButton(
            identifier: "decomposition-split-\(first.id.uuidString)",
            in: host.view
        )
        #expect(split.title == DecompositionWorkbenchCopy.continueSplit)
        #expect(split.isBordered == false)
        let advance = try uniqueButton(identifier: "decomposition-advance", in: host.view)
        #expect(advance.isBordered == true)
        #expect(split.bezelStyle != advance.bezelStyle)

        let collapsedSplit = try uniqueButton(
            identifier: "decomposition-split-\(second.id.uuidString)",
            in: host.view
        )
        #expect(collapsedSplit.isBordered == false)

        let manual = try await WorkbenchPresentationFixture.make(
            planner: UnavailableDecompositionPlanner(reason: .deviceNotEligible)
        )
        await manual.model.start()
        let manualHost = hostedWorkbench(
            manual.model,
            size: DecompositionWorkbenchMetrics.targetSize
        )
        defer { manualHost.window.orderOut(nil) }
        let manualID = try #require(manual.model.draft.candidates.first).id
        #expect(
            findButton(in: manualHost.view, identifier: "decomposition-split-\(manualID.uuidString)")
                == nil
        )

        let editor = try actionEditorSource()
        #expect(editor.contains("theme.selectionFill"))
        #expect(editor.contains("theme.selectionOutline"))
        #expect(editor.contains("theme.subtleBorder"))
        #expect(editor.contains("CalendarTheme.cornerRadius"))
        #expect(editor.contains("visualTitle:"))
        #expect(editor.contains("\"创建\"") || editor.contains("createAction"))
        #expect(editor.contains("做到什么算完成？") || editor.contains("completionPlaceholder"))
        #expect(!editor.contains("LinearGradient"))
        #expect(!editor.contains(".largeTitle"))
        #expect(!editor.contains(".title2"))
        #expect(!editor.contains(".title3"))
        #expect(!editor.contains("Capsule()"))
        #expect(!editor.contains("Font.system(size: 11"))
        #expect(!editor.contains("Font.system(size: 13"))
        #expect(!editor.contains("Font.system(size: 17"))
        #expect(!editor.contains("Font.system(size: 18"))
        #expect(!editor.contains("Font.system(size: 22"))
        #expect(!editor.contains("Font.system(size: 28"))
        #expect(!editor.contains("selectionFillHex"))
        #expect(!editor.contains("Color(red:"))
        #expect(editor.contains("if case .manual"))
        #expect(editor.contains("DecompositionWorkbenchCopy.continueSplit"))
    }

    @Test func noProposalShowsExplicitChooseTimeWithoutFakeNineAM() async throws {
        let fixture = try await WorkbenchPresentationFixture.splitWithoutAvailableSlot()
        let first = try #require(fixture.model.draft.candidates.first)
        #expect(fixture.model.draft.stage == .schedule)
        #expect(first.selectedForCalendar)
        #expect(first.proposal == nil)
        #expect(!first.scheduleLockedByUser)

        let host = hostedWorkbench(fixture.model, size: DecompositionWorkbenchMetrics.targetSize)
        defer { host.window.orderOut(nil) }
        let id = first.id.uuidString
        let labels = accessibilityLabels(in: host.view)
        #expect(labels.contains { $0.contains("未来七天没有合适空档") })
        #expect(findButton(in: host.view, identifier: "decomposition-choose-time-\(id)")?.title == "选择日期与时间")
        #expect(findView(in: host.view, identifier: "decomposition-time-\(id)") == nil)
        #expect(findView(in: host.view, identifier: "decomposition-date-\(id)") == nil)
        #expect(findView(in: host.view, identifier: "decomposition-duration-\(id)") == nil)
        #expect(!hasIdentifiedControl(identifier: "decomposition-time-\(id)", in: host.view))
        #expect(!hasIdentifiedControl(identifier: "decomposition-date-\(id)", in: host.view))
        #expect(!hasIdentifiedControl(identifier: "decomposition-duration-\(id)", in: host.view))
        #expect(!labels.contains { $0.contains("09:00") })
        #expect(!labels.contains("开始时间"))
        #expect(!labels.contains("日期"))

        let choose = try uniqueButton(identifier: "decomposition-choose-time-\(id)", in: host.view)
        #expect(choose.isBordered)
        choose.performClick(nil)
        #expect(await waitUntil {
            host.view.layoutSubtreeIfNeeded()
            let labels = accessibilityLabels(in: host.view)
            return fixture.model.draft.candidates[0].proposal != nil
                && fixture.model.draft.candidates[0].scheduleLockedByUser
                && findButton(in: host.view, identifier: "decomposition-choose-time-\(id)") == nil
                && (
                    hasIdentifiedControl(identifier: "decomposition-date-\(id)", in: host.view)
                        || labels.contains("日期")
                )
                && (
                    hasIdentifiedControl(identifier: "decomposition-time-\(id)", in: host.view)
                        || labels.contains("开始时间")
                )
                && (
                    hasIdentifiedControl(identifier: "decomposition-duration-\(id)", in: host.view)
                        || labels.contains("预计时长")
                )
                && descendants(of: host.view, as: NSTextField.self).contains {
                    $0.stringValue == "已调整" && $0.font?.pointSize == 12
                }
        })

        #expect(fixture.model.draft.candidates[0].proposal != nil)
        #expect(fixture.model.draft.candidates[0].scheduleLockedByUser)
        #expect(findButton(in: host.view, identifier: "decomposition-choose-time-\(id)") == nil)
        let updatedLabels = accessibilityLabels(in: host.view)
        #expect(
            hasIdentifiedControl(identifier: "decomposition-time-\(id)", in: host.view)
                || updatedLabels.contains("开始时间")
        )
        #expect(
            hasIdentifiedControl(identifier: "decomposition-date-\(id)", in: host.view)
                || updatedLabels.contains("日期")
        )
        #expect(
            hasIdentifiedControl(identifier: "decomposition-duration-\(id)", in: host.view)
                || updatedLabels.contains("预计时长")
        )

        let adjusted = descendants(of: host.view, as: NSTextField.self).first {
            $0.stringValue == "已调整"
        }
        #expect(adjusted != nil)
        #expect(adjusted?.font?.pointSize == 12)

        #expect(DecompositionWorkbenchMetrics.resultHeight == 64)
        let summary = try #require(
            findTextField(in: host.view, identifier: "decomposition-result-summary")
        )
        #expect(
            isInBottomBand(
                summary.convert(summary.bounds, to: host.view),
                hostBounds: host.view.bounds,
                height: DecompositionWorkbenchMetrics.resultHeight,
                tolerance: 2
            )
        )

        let schedule = try scheduleEditorSource()
        #expect(schedule.contains("theme.elevatedSurface"))
        #expect(schedule.contains("theme.subtleBorder"))
        #expect(schedule.contains("CalendarTheme.cornerRadius"))
        #expect(schedule.contains("overwriteUserAdjustments: false"))
        #expect(schedule.contains("beginManualCalendarProposal"))
        #expect(schedule.contains("未来七天没有合适空档") || schedule.contains("noAvailableSlot"))
        #expect(schedule.contains("选择日期与时间") || schedule.contains("chooseDateAndTime"))
        #expect(schedule.contains("已调整") || schedule.contains("adjustedSchedule"))
        #expect(schedule.contains("spacing: 12") || schedule.contains("spacing: 16"))
        #expect(!schedule.contains("LinearGradient"))
        #expect(!schedule.contains(".shadow("))
        #expect(!schedule.contains("struct DecompositionScheduleCard"))
    }
}

private struct HostedWorkbench {
    let view: NSView
    let window: NSWindow
}

@MainActor
private func hostedWorkbench(
    _ model: DecompositionWorkbenchModel,
    size: CGSize,
    colorScheme: ColorScheme? = nil
) -> HostedWorkbench {
    _ = NSApplication.shared
    let workbench = DecompositionWorkbenchView(model: model, onCancel: {}, onCommitted: { _ in })
        .frame(width: size.width, height: size.height)
    let root: AnyView
    if let colorScheme {
        root = AnyView(
            workbench
                .environment(\.colorScheme, colorScheme)
                .preferredColorScheme(colorScheme)
        )
    } else {
        root = AnyView(workbench)
    }
    let hosting = NSHostingView(rootView: root)
    hosting.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(
        contentRect: hosting.frame,
        styleMask: [],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.isRestorable = false
    if let colorScheme {
        window.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    return .init(view: hosting, window: window)
}

@MainActor
private struct WorkbenchPresentationFixture {
    let model: DecompositionWorkbenchModel
    let store: WorkspaceStore

    static let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    static let now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai
        return calendar.date(from: DateComponents(year: 2026, month: 8, day: 22, hour: 8, minute: 0))!
    }()

    static func make(
        planner: any DecompositionPlanning,
        uuid: @escaping @Sendable () -> UUID = UUID.init,
        snapshotRevisionOffset: Int64 = 0,
        sourceText: String = "预约牙医",
        wholeNote: Bool = false
    ) async throws -> WorkbenchPresentationFixture {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let blockID = BlockID()
        var note = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: now)
        note.document = .init(blocks: [
            .init(
                id: blockID,
                kind: .paragraph,
                inlineContent: .plain(sourceText),
                taskState: nil,
                indentLevel: 0
            )
        ])
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let persisted = try #require(store.state.notes[note.id])
        let focusOffset = wholeNote ? 0 : 4
        var snapshot = try DecompositionSourceCapture.capture(
            note: persisted,
            workspaceRevision: store.state.revision,
            selection: .text(
                anchor: .init(blockID: blockID, graphemeOffset: 0),
                focus: .init(blockID: blockID, graphemeOffset: focusOffset),
                preferredColumn: nil,
                typingAttributes: .init(marks: [], linkURL: nil)
            )
        )
        if snapshotRevisionOffset != 0 {
            snapshot = DecompositionSourceSnapshot(
                noteID: snapshot.noteID,
                noteRevision: snapshot.noteRevision + snapshotRevisionOffset,
                workspaceRevision: snapshot.workspaceRevision,
                sourceBlockID: snapshot.sourceBlockID,
                selectedRange: snapshot.selectedRange,
                normalizedText: snapshot.normalizedText,
                noteChecksum: snapshot.noteChecksum,
                sourceChecksum: snapshot.sourceChecksum
            )
        }
        let clockNow = now
        let model = DecompositionWorkbenchModel(
            snapshot: snapshot,
            planner: planner,
            store: store,
            clock: { clockNow },
            timeZone: shanghai,
            uuid: uuid
        )
        return .init(model: model, store: store)
    }

    static func splitWithScheduledActions(
        snapshotRevisionOffset: Int64 = 0
    ) async throws -> WorkbenchPresentationFixture {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000901")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000902")!
        let third = UUID(uuidString: "00000000-0000-0000-0000-000000000903")!
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
                        completionDescription: "把证件和钥匙放一起",
                        estimatedMinutes: 30
                    ),
                    PlannerCandidate(
                        existingID: nil,
                        title: "记录结果",
                        completionDescription: "写下对方给出的时间",
                        estimatedMinutes: 15
                    )
                ])
            ]),
            uuid: SequentialWorkbenchUUID([first, second, third]).next,
            snapshotRevisionOffset: snapshotRevisionOffset
        )
        await fixture.model.start()
        _ = try #require(fixture.model.draft.candidates.count == 3)
        fixture.model.setSelectedForCalendar(id: first, selected: true)
        fixture.model.setSelectedForCalendar(id: second, selected: true)
        fixture.model.advanceToSchedule()
        fixture.model.returnToStage(.split)
        return fixture
    }

    static func splitWithoutAvailableSlot() async throws -> WorkbenchPresentationFixture {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000941")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000942")!
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
                        completionDescription: "把证件和钥匙放一起",
                        estimatedMinutes: 30
                    )
                ])
            ]),
            uuid: SequentialWorkbenchUUID([first, second]).next
        )
        try await occupyNextSevenDays(in: fixture.store)
        await fixture.model.start()
        let candidate = try #require(fixture.model.draft.candidates.first)
        fixture.model.setSelectedForCalendar(id: candidate.id, selected: true)
        fixture.model.advanceToSchedule()
        return fixture
    }

    static func occupyNextSevenDays(in store: WorkspaceStore) async throws {
        let today = CalendarDate.localDay(containing: now, in: shanghai)
        let categoryID = store.state.calendar.uncategorizedID
        for offset in 0...6 {
            let day = today.addingDays(offset)
            let item = try CalendarItem(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000d7\(offset)")!,
                kind: .task,
                title: "占满空档",
                categoryID: categoryID,
                schedule: try CalendarSchedule(
                    startDate: day,
                    endDate: day,
                    startTime: MinuteOfDay(hour: 9, minute: 0),
                    endTime: MinuteOfDay(hour: 21, minute: 0)
                ),
                creationTimeZoneIdentifier: shanghai.identifier,
                completedAt: nil,
                createdAt: now,
                updatedAt: now
            )
            _ = try await store.sendCalendar(.createItem(item), undoLabel: "占满")
        }
    }

    static func understandWithQuestion() async throws -> WorkbenchPresentationFixture {
        let fixture = try await make(
            planner: ScriptedDecompositionPlanner([
                .clarification(.ask(
                    question: "完成后最重要的结果是什么？",
                    quickAnswers: ["拿到确认"]
                ))
            ])
        )
        await fixture.model.start()
        return fixture
    }
}

private final class SequentialWorkbenchUUID: @unchecked Sendable {
    private var values: [UUID]
    init(_ values: [UUID]) { self.values = values }
    func next() -> UUID {
        values.isEmpty ? UUID() : values.removeFirst()
    }
}

private struct ImmediateWorkbenchSleeper: DecompositionSleeping {
    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
    }
}

private actor SleepingWorkbenchPlanner: DecompositionPlanning {
    nonisolated var availability: DecompositionPlannerAvailability { .available }

    func clarification(for request: ClarificationRequest) async throws -> ClarificationDecision {
        try await Task.sleep(for: .seconds(60 * 60))
        throw ScriptedPlannerFailure.exhausted
    }

    func candidates(for request: CandidateRequest) async throws -> [PlannerCandidate] {
        throw ScriptedPlannerFailure.exhausted
    }

    func splitCandidate(for request: SplitCandidateRequest) async throws -> [PlannerCandidate] {
        throw ScriptedPlannerFailure.exhausted
    }
}

@MainActor
private func workbenchSources() throws -> String {
    let files = [
        "Sources/CalendarApp/Decomposition/DecompositionWorkbenchView.swift",
        "Sources/CalendarApp/Decomposition/DecompositionConversationPane.swift",
        "Sources/CalendarApp/Decomposition/DecompositionActionEditor.swift",
        "Sources/CalendarApp/Decomposition/DecompositionScheduleEditor.swift"
    ]
    return try files.map { path in
        try String(contentsOf: workbenchSourceRoot().appending(path: path), encoding: .utf8)
    }.joined(separator: "\n")
}

@MainActor
private func workbenchViewSource() throws -> String {
    try String(
        contentsOf: workbenchSourceRoot().appending(
            path: "Sources/CalendarApp/Decomposition/DecompositionWorkbenchView.swift"
        ),
        encoding: .utf8
    )
}

@MainActor
private func workbenchConversationSource() throws -> String {
    try String(
        contentsOf: workbenchSourceRoot().appending(
            path: "Sources/CalendarApp/Decomposition/DecompositionConversationPane.swift"
        ),
        encoding: .utf8
    )
}

@MainActor
private func actionEditorSource() throws -> String {
    try String(
        contentsOf: workbenchSourceRoot().appending(
            path: "Sources/CalendarApp/Decomposition/DecompositionActionEditor.swift"
        ),
        encoding: .utf8
    )
}

@MainActor
private func scheduleEditorSource() throws -> String {
    try String(
        contentsOf: workbenchSourceRoot().appending(
            path: "Sources/CalendarApp/Decomposition/DecompositionScheduleEditor.swift"
        ),
        encoding: .utf8
    )
}

private func workbenchSourceRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

@MainActor
private func expectInvalidField(
    _ field: NSTextField,
    reason: String,
    identifier: String,
    in root: NSView
) throws {
    #expect(axInvalidValue(of: field) == "true")
    #expect(field.isAccessibilityRequired() == true)
    let help = field.accessibilityHelp() ?? field.toolTip
    #expect(help == reason)
    let message = try #require(findTextField(in: root, identifier: identifier))
    #expect(message.stringValue == reason)
    #expect(message.font?.pointSize == 12)
    #expect(nsColorsMatch(message.textColor, NSColor(CalendarTheme.light.error)))
}

@MainActor
private func axInvalidValue(of field: NSTextField?) -> String? {
    guard let field else { return nil }
    return field.accessibilityAttributeValue(
        NSAccessibility.Attribute(rawValue: "AXInvalid")
    ) as? String
}

@MainActor
private func expectHostedResultSummary(
    _ model: DecompositionWorkbenchModel,
    _ expected: String
) throws {
    let host = hostedWorkbench(model, size: DecompositionWorkbenchMetrics.targetSize)
    defer { host.window.orderOut(nil) }
    let summary = try #require(
        findTextField(in: host.view, identifier: "decomposition-result-summary")
    )
    #expect(summary.stringValue == expected)
}

@MainActor
private func accessibilityLabels(in view: NSView) -> [String] {
    var labels: [String] = []
    var visited = Set<ObjectIdentifier>()
    collectAccessibilityLabels(from: view, into: &labels, visited: &visited)
    return Array(Set(labels))
}

@MainActor
private func collectAccessibilityLabels(from object: Any, into labels: inout [String], visited: inout Set<ObjectIdentifier>) {
    let candidate = object as AnyObject
    let identity = ObjectIdentifier(candidate)
    guard visited.insert(identity).inserted else { return }
    if let children = candidate.accessibilityChildren?() {
        for child in children {
            collectAccessibilityLabels(from: child, into: &labels, visited: &visited)
        }
    }
    if let label = candidate.accessibilityLabel?(), !label.isEmpty {
        labels.append(label)
    }
    if let button = object as? NSButton, !button.title.isEmpty {
        labels.append(button.title)
    }
    if let field = object as? NSTextField, !field.stringValue.isEmpty {
        labels.append(field.stringValue)
    }
    if let view = object as? NSView {
        for subview in view.subviews {
            collectAccessibilityLabels(from: subview, into: &labels, visited: &visited)
        }
    }
}

@MainActor
private func views(withIdentifier identifier: String, in root: NSView) -> [NSView] {
    descendants(of: root, as: NSView.self).filter {
        $0.accessibilityIdentifier() == identifier
    }
}

@MainActor
private func findButton(in root: NSView, identifier: String) -> NSButton? {
    descendants(of: root, as: NSButton.self).first {
        $0.accessibilityIdentifier() == identifier
    }
}

@MainActor
private func findView(in root: NSView, identifier: String) -> NSView? {
    descendants(of: root, as: NSView.self).first {
        $0.accessibilityIdentifier() == identifier
    }
}

@MainActor
private func hasIdentifiedControl(identifier: String, in root: NSView) -> Bool {
    if findView(in: root, identifier: identifier) != nil {
        return true
    }
    return accessibilityObjects(from: root).contains { object in
        object.accessibilityIdentifier?() == identifier
    }
}

@MainActor
private func findTextField(in root: NSView, identifier: String) -> NSTextField? {
    descendants(of: root, as: NSTextField.self).first {
        $0.accessibilityIdentifier() == identifier
    }
}

@MainActor
private func uniqueMultilineTextField(
    identifier: String,
    in root: NSView
) throws -> DecompositionMultilineNSTextField {
    let matches = views(withIdentifier: identifier, in: root)
    #expect(matches.count == 1)
    let field = try #require(matches.first as? DecompositionMultilineNSTextField)
    #expect(field.isEditable)
    #expect(field.isSelectable)
    #expect(field.isAccessibilityElement() == true)
    #expect(field.accessibilityRole() == .textField)
    #expect(field.cell?.isAccessibilityElement() != true)
    #expect(field.focusRingType != .none)
    #expect(field.cell?.focusRingType != NSFocusRingType.none)
    return field
}

@MainActor
private func uniqueEditableTextField(
    identifier: String,
    in root: NSView
) throws -> NSTextField {
    let matches = views(withIdentifier: identifier, in: root)
    #expect(matches.count == 1)
    let field = try #require(matches.first as? NSTextField)
    #expect(field.isEditable)
    #expect(field.focusRingType != .none)
    #expect(field.cell?.focusRingType != NSFocusRingType.none)
    return field
}

@MainActor
private func expectStageButtons(in view: NSView, current: DecompositionStage) throws {
    for stage in DecompositionStage.allCases {
        let button = try uniqueButton(
            identifier: "decomposition-stage-\(stage.rawValue)",
            in: view
        )
        let value = button.accessibilityValue() as? String
        if stage == current {
            #expect(button.isEnabled == true)
            #expect(value == "当前步骤")
            #expect(button.isAccessibilitySelected() == true)
            #expect((button.layer?.backgroundColor?.alpha ?? 0) > 0)
        } else if stage.rawValue < current.rawValue {
            #expect(button.isEnabled == true)
            #expect(value == "已完成步骤")
            #expect(button.isAccessibilitySelected() != true)
            #expect(button.alphaValue < 1)
        } else {
            #expect(button.isEnabled == false)
            #expect(value == "未到达步骤")
            #expect(button.isAccessibilitySelected() != true)
        }
    }
}

@MainActor
private func uniqueButton(identifier: String, in root: NSView) throws -> NSButton {
    let matches = views(withIdentifier: identifier, in: root)
    #expect(matches.count == 1)
    return try #require(matches.first as? NSButton)
}

@MainActor
private func accessibilityObjects(from object: Any) -> [AnyObject] {
    var collected: [AnyObject] = []
    var visited = Set<ObjectIdentifier>()
    collectAccessibilityObjects(from: object, into: &collected, visited: &visited)
    return collected
}

@MainActor
private func collectAccessibilityObjects(
    from object: Any,
    into collected: inout [AnyObject],
    visited: inout Set<ObjectIdentifier>
) {
    let candidate = object as AnyObject
    let identity = ObjectIdentifier(candidate)
    guard visited.insert(identity).inserted else { return }
    collected.append(candidate)
    if let children = candidate.accessibilityChildren?() {
        for child in children {
            collectAccessibilityObjects(from: child, into: &collected, visited: &visited)
        }
    }
    if let view = object as? NSView {
        for subview in view.subviews {
            collectAccessibilityObjects(from: subview, into: &collected, visited: &visited)
        }
    }
}

@MainActor
private func uniqueCheckbox(identifier: String, in root: NSView) throws -> NSButton {
    let objects = accessibilityObjects(from: root)
    let matches = objects.compactMap { $0 as? NSButton }.filter { button in
        button.accessibilityIdentifier() == identifier
            && button.accessibilityRole() == .checkBox
    }
    #expect(matches.count == 1)
    return try #require(matches.first)
}

@MainActor
private func checkboxes(in root: NSView) -> [NSButton] {
    let objects = accessibilityObjects(from: root)
    return objects.compactMap { $0 as? NSButton }.filter { button in
        button.accessibilityRole() == .checkBox
    }
}

@MainActor
private func expectHeightWithinVisibleLines(
    _ height: CGFloat,
    lineHeight: CGFloat,
    tolerance: CGFloat = 2
) {
    let lines = DecompositionMultilineNSTextField.minLines...DecompositionMultilineNSTextField.maxLines
    let minimum = lineHeight * CGFloat(lines.lowerBound) - tolerance
    let maximum = lineHeight * CGFloat(lines.upperBound) + tolerance
    #expect(height >= minimum)
    #expect(height <= maximum)
}

private func isInBottomBand(
    _ frame: CGRect,
    hostBounds: CGRect,
    height: CGFloat,
    tolerance: CGFloat
) -> Bool {
    let nearUnflippedBottom =
        frame.minY >= hostBounds.minY - tolerance
        && frame.maxY <= hostBounds.minY + height + tolerance
    let nearFlippedBottom =
        frame.minY >= hostBounds.maxY - height - tolerance
        && frame.maxY <= hostBounds.maxY + tolerance
    return nearUnflippedBottom || nearFlippedBottom
}

@MainActor
private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
    let own = (view as? T).map { [$0] } ?? []
    return own + view.subviews.flatMap { descendants(of: $0, as: type) }
}

@MainActor
private func uniqueSourceTextField(in root: NSView) throws -> NSTextField {
    let matches = views(withIdentifier: "decomposition-source-text", in: root)
    #expect(matches.count == 1)
    return try #require(matches.first as? NSTextField)
}

@MainActor
private func expectSourceTextColor(
    _ field: NSTextField,
    matches theme: CalendarSemanticAppearance
) {
    let expected = NSColor(theme.secondaryText)
    #expect(nsColorsMatch(field.textColor, expected))
}

@MainActor
private func nsColorsMatch(_ lhs: NSColor?, _ rhs: NSColor, accuracy: CGFloat = 0.02) -> Bool {
    guard let lhs, let actual = lhs.usingColorSpace(.sRGB), let expected = rhs.usingColorSpace(.sRGB) else {
        return false
    }
    return abs(actual.redComponent - expected.redComponent) <= accuracy
        && abs(actual.greenComponent - expected.greenComponent) <= accuracy
        && abs(actual.blueComponent - expected.blueComponent) <= accuracy
}

@MainActor
private func enclosingScrollView(from view: NSView) -> NSScrollView? {
    var current: NSView? = view
    while let node = current {
        if let scroll = node as? NSScrollView {
            return scroll
        }
        current = node.superview
    }
    return nil
}

@MainActor
private func stackedSourcePaneHeight(from view: NSView) -> CGFloat {
    var current: NSView? = view
    while let node = current {
        let height = node.bounds.height
        if height >= 168, height <= 228 {
            return height
        }
        current = node.superview
    }
    return view.bounds.height
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
