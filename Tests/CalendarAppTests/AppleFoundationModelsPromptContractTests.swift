import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("AppleFoundationModelsPromptContractTests")
struct AppleFoundationModelsPromptContractTests {
    @Test func instructionsContainEveryRequiredConstraintVerbatim() {
        let text = DecompositionPromptBuilder.instructions
        let required = [
            "只问一个关键问题或明确无需追问",
            "初始 2～5",
            "行动可独立完成",
            "完成说明可观察",
            "不得把父意图安排",
            "只返回给定时长",
            "不得覆盖标记为 locked 的字段",
            "局部重拆不谈其他候选",
            "中文输入用中文回答"
        ]
        for constraint in required {
            #expect(text.contains(constraint), "缺少约束：\(constraint)")
        }
    }

    @Test func clarificationPromptCarriesSourceAndDoesNotImportFrameworkTypes() throws {
        let source = try makeSnapshot()
        let prompt = DecompositionPromptBuilder.clarification(
            ClarificationRequest(source: source)
        )
        #expect(prompt.contains(source.normalizedText))
        #expect(prompt.contains("只问一个关键问题或明确无需追问"))
        assertNoFrameworkLeak(prompt)
        assertNoFrameworkLeak(DecompositionPromptBuilder.instructions)
    }

    @Test func candidatePromptIncludesLockedFieldsAndDurationContract() throws {
        let source = try makeSnapshot()
        let lockedID = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
        let prompt = DecompositionPromptBuilder.candidates(
            CandidateRequest(
                source: source,
                answer: "拿到确认",
                existingCandidates: [
                    PlannerCandidateContext(
                        id: lockedID,
                        title: "给物业打电话",
                        completionDescription: "拿到明确上门时间",
                        estimatedMinutes: 30,
                        titleLockedByUser: true,
                        completionLockedByUser: false
                    )
                ],
                validationFeedback: .invalidCount(1)
            )
        )
        #expect(prompt.contains("拿到确认"))
        #expect(prompt.contains(lockedID.uuidString))
        #expect(prompt.contains("titleLockedByUser=true"))
        #expect(prompt.contains("不得覆盖标记为 locked 的字段"))
        #expect(prompt.contains("只返回给定时长"))
        #expect(prompt.contains("15 / 30 / 45 / 60 / 90"))
        #expect(prompt.contains("初始 2～5"))
        assertNoFrameworkLeak(prompt)
    }

    @Test func splitPromptOmitsOtherCandidatesAndKeepsChineseContract() throws {
        let source = try makeSnapshot()
        let prompt = DecompositionPromptBuilder.split(
            SplitCandidateRequest(
                source: source,
                answer: "先找到电话",
                target: PlannerCandidateContext(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000402")!,
                    title: "给物业打电话",
                    completionDescription: "拿到明确上门时间",
                    estimatedMinutes: 15,
                    titleLockedByUser: false,
                    completionLockedByUser: true
                ),
                validationFeedback: nil
            )
        )
        #expect(prompt.contains("给物业打电话"))
        #expect(prompt.contains("局部重拆不谈其他候选"))
        #expect(prompt.contains("中文输入用中文回答"))
        #expect(prompt.contains("行动可独立完成"))
        #expect(prompt.contains("完成说明可观察"))
        #expect(prompt.contains("不得把父意图安排"))
        assertNoFrameworkLeak(prompt)
    }

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @Test func handwrittenGenerableSchemasRoundTripActionAndClarificationContent() throws {
        _ = GeneratedActionList.generationSchema
        _ = GeneratedClarification.generationSchema

        let identifiedID = "00000000-0000-0000-0000-000000000501"
        let identified = try GeneratedAction(
            GeneratedContent(properties: [
                "existingID": identifiedID,
                "title": "给物业打电话",
                "completionDescription": "拿到明确上门时间",
                "estimatedMinutes": 30
            ])
        )
        #expect(identified.existingID == identifiedID)
        #expect(identified.title == "给物业打电话")
        #expect(identified.completionDescription == "拿到明确上门时间")
        #expect(identified.estimatedMinutes == 30)

        let identifiedAgain = try GeneratedAction(identified.generatedContent)
        #expect(identifiedAgain.existingID == identifiedID)
        #expect(identifiedAgain.title == identified.title)
        #expect(identifiedAgain.completionDescription == identified.completionDescription)
        #expect(identifiedAgain.estimatedMinutes == identified.estimatedMinutes)

        let untitledID = try GeneratedAction(
            GeneratedContent(properties: [
                "existingID": nil as String?,
                "title": "记录上门时间",
                "completionDescription": "把确认写进笔记",
                "estimatedMinutes": 15
            ])
        )
        #expect(untitledID.existingID == nil)
        #expect(untitledID.title == "记录上门时间")
        #expect(untitledID.completionDescription == "把确认写进笔记")
        #expect(untitledID.estimatedMinutes == 15)

        let untitledAgain = try GeneratedAction(untitledID.generatedContent)
        #expect(untitledAgain.existingID == nil)
        #expect(untitledAgain.title == untitledID.title)
        #expect(untitledAgain.completionDescription == untitledID.completionDescription)
        #expect(untitledAgain.estimatedMinutes == untitledID.estimatedMinutes)

        let list = try GeneratedActionList(
            GeneratedContent(properties: [
                "actions": [identified, untitledID]
            ])
        )
        #expect(list.actions.count == 2)
        #expect(list.actions[0].existingID == identifiedID)
        #expect(list.actions[1].existingID == nil)
        let listAgain = try GeneratedActionList(list.generatedContent)
        #expect(listAgain.actions.map(\.existingID) == [identifiedID, nil])
        #expect(listAgain.actions.map(\.title) == ["给物业打电话", "记录上门时间"])
        #expect(listAgain.actions.map(\.completionDescription) == ["拿到明确上门时间", "把确认写进笔记"])
        #expect(listAgain.actions.map(\.estimatedMinutes) == [30, 15])

        let clarification = try GeneratedClarification(
            GeneratedContent(properties: [
                "needsFollowUp": true,
                "question": "完成后最重要的结果是什么？",
                "quickAnswers": ["拿到确认", "先找电话"]
            ])
        )
        #expect(clarification.needsFollowUp == true)
        #expect(clarification.question == "完成后最重要的结果是什么？")
        #expect(clarification.quickAnswers == ["拿到确认", "先找电话"])
        let clarificationAgain = try GeneratedClarification(clarification.generatedContent)
        #expect(clarificationAgain.needsFollowUp == clarification.needsFollowUp)
        #expect(clarificationAgain.question == clarification.question)
        #expect(clarificationAgain.quickAnswers == clarification.quickAnswers)
    }
#endif

    private func makeSnapshot() throws -> DecompositionSourceSnapshot {
        let blockID = BlockID()
        var note = Note.empty(id: NoteID(), categoryID: UUID(), now: .distantPast)
        note.document = .init(blocks: [
            .init(id: blockID, kind: .paragraph, inlineContent: .plain("预约牙医"), taskState: nil, indentLevel: 0)
        ])
        return try DecompositionSourceCapture.capture(
            note: note,
            workspaceRevision: 1,
            selection: .text(
                anchor: .init(blockID: blockID, graphemeOffset: 0),
                focus: .init(blockID: blockID, graphemeOffset: 4),
                preferredColumn: nil,
                typingAttributes: .init(marks: [], linkURL: nil)
            )
        )
    }

    private func assertNoFrameworkLeak(_ text: String) {
        #expect(!text.contains("FoundationModels"))
        #expect(!text.contains("LanguageModelSession"))
        #expect(!text.contains("SystemLanguageModel"))
        #expect(!text.contains("@Generable"))
    }
}
