import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

enum ScriptedPlannerFailure: Error, Equatable {
    case requestedFailure
    case exhausted
}

actor ScriptedDecompositionPlanner: DecompositionPlanning {
    nonisolated let availability: DecompositionPlannerAvailability

    enum Response: Sendable {
        case clarification(ClarificationDecision)
        case candidates([PlannerCandidate])
        case failure(ScriptedPlannerFailure)
    }

    private var responses: [Response]

    init(
        _ responses: [Response],
        availability: DecompositionPlannerAvailability = .available
    ) {
        self.responses = responses
        self.availability = availability
    }

    func clarification(for request: ClarificationRequest) async throws -> ClarificationDecision {
        switch try pop() {
        case let .clarification(decision):
            return decision
        case .candidates:
            throw ScriptedPlannerFailure.exhausted
        case let .failure(failure):
            throw failure
        }
    }

    func candidates(for request: CandidateRequest) async throws -> [PlannerCandidate] {
        try popCandidates()
    }

    func splitCandidate(for request: SplitCandidateRequest) async throws -> [PlannerCandidate] {
        try popCandidates()
    }

    private func popCandidates() throws -> [PlannerCandidate] {
        switch try pop() {
        case let .candidates(items):
            return items
        case .clarification:
            throw ScriptedPlannerFailure.exhausted
        case let .failure(failure):
            throw failure
        }
    }

    private func pop() throws -> Response {
        guard !responses.isEmpty else {
            throw ScriptedPlannerFailure.exhausted
        }
        return responses.removeFirst()
    }
}

@Suite("DecompositionPlanningContractTests")
struct DecompositionPlanningContractTests {
    @Test func planningRequestsDoNotCarryWorkspaceStore() throws {
        let source = try makeSnapshot()
        let target = PlannerCandidateContext(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000321")!,
            title: "给物业打电话",
            completionDescription: "拿到明确上门时间",
            estimatedMinutes: 30,
            titleLockedByUser: true,
            completionLockedByUser: false
        )
        let clarification = ClarificationRequest(source: source)
        let candidates = CandidateRequest(
            source: source,
            answer: "拿到确认",
            existingCandidates: [target],
            validationFeedback: .invalidCount(1)
        )
        let split = SplitCandidateRequest(
            source: source,
            answer: nil,
            target: target,
            validationFeedback: nil
        )

        #expect(labels(of: clarification) == ["source"])
        #expect(labels(of: candidates) == ["source", "answer", "existingCandidates", "validationFeedback"])
        #expect(labels(of: split) == ["source", "answer", "target", "validationFeedback"])
        assertNoWorkspaceStore(clarification)
        assertNoWorkspaceStore(candidates)
        assertNoWorkspaceStore(split)
        assertNoWorkspaceStore(source)
        assertNoWorkspaceStore(target)
    }

    @Test func scriptedPlannerConsumesResponsesAndDoesNotTouchAStore() async throws {
        let source = try makeSnapshot()
        let planner = ScriptedDecompositionPlanner([
            .clarification(.ask(question: "完成后最重要的结果是什么？", quickAnswers: ["拿到确认"])),
            .candidates([
                PlannerCandidate(
                    existingID: nil,
                    title: "给物业打电话",
                    completionDescription: "拿到明确上门时间",
                    estimatedMinutes: 15
                ),
                PlannerCandidate(
                    existingID: nil,
                    title: "记录上门时间",
                    completionDescription: "把确认写进笔记",
                    estimatedMinutes: 30
                )
            ]),
            .candidates([
                PlannerCandidate(
                    existingID: nil,
                    title: "先查电话",
                    completionDescription: "找到物业电话",
                    estimatedMinutes: 15
                ),
                PlannerCandidate(
                    existingID: nil,
                    title: "再打电话",
                    completionDescription: "打通并确认上门",
                    estimatedMinutes: 45
                )
            ])
        ])
        #expect(planner.availability == .available)

        let decision = try await planner.clarification(for: ClarificationRequest(source: source))
        #expect(decision == .ask(question: "完成后最重要的结果是什么？", quickAnswers: ["拿到确认"]))

        let generated = try await planner.candidates(
            for: CandidateRequest(
                source: source,
                answer: "拿到确认",
                existingCandidates: [],
                validationFeedback: nil
            )
        )
        #expect(generated.count == 2)
        #expect(generated[0].title == "给物业打电话")

        let split = try await planner.splitCandidate(
            for: SplitCandidateRequest(
                source: source,
                answer: "先找到电话",
                target: PlannerCandidateContext(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000322")!,
                    title: "给物业打电话",
                    completionDescription: "拿到明确上门时间",
                    estimatedMinutes: 15,
                    titleLockedByUser: false,
                    completionLockedByUser: false
                ),
                validationFeedback: nil
            )
        )
        #expect(split.map(\.title) == ["先查电话", "再打电话"])
        #expect(split.allSatisfy { $0.existingID == nil })
    }

    @Test func scriptedPlannerThrowsRequestedAndExhaustedFailures() async throws {
        let source = try makeSnapshot()
        let failing = ScriptedDecompositionPlanner([.failure(.requestedFailure)])
        await #expect(throws: ScriptedPlannerFailure.requestedFailure) {
            try await failing.clarification(for: ClarificationRequest(source: source))
        }

        let empty = ScriptedDecompositionPlanner([])
        await #expect(throws: ScriptedPlannerFailure.exhausted) {
            try await empty.candidates(
                for: CandidateRequest(
                    source: source,
                    answer: nil,
                    existingCandidates: [],
                    validationFeedback: nil
                )
            )
        }

        let skipped = ScriptedDecompositionPlanner([
            .clarification(.notNeeded)
        ])
        await #expect(throws: ScriptedPlannerFailure.exhausted) {
            try await skipped.splitCandidate(
                for: SplitCandidateRequest(
                    source: source,
                    answer: nil,
                    target: PlannerCandidateContext(
                        id: UUID(),
                        title: "目标",
                        completionDescription: "完成目标",
                        estimatedMinutes: 30,
                        titleLockedByUser: false,
                        completionLockedByUser: false
                    ),
                    validationFeedback: nil
                )
            )
        }
    }

    @Test func unavailablePlannerReportsManualReasonWithoutAStore() {
        let planner = ScriptedDecompositionPlanner(
            [],
            availability: .unavailable(.localeUnsupported)
        )
        #expect(planner.availability == .unavailable(.localeUnsupported))
    }
}

private func makeSnapshot() throws -> DecompositionSourceSnapshot {
    let blockID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000301")!)
    var note = Note.empty(
        id: NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000300")!),
        categoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
        now: .distantPast
    )
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

private func labels<T>(of value: T) -> [String] {
    Mirror(reflecting: value).children.compactMap(\.label)
}

private func assertNoWorkspaceStore<T>(_ value: T) {
    let typeName = String(describing: T.self)
    #expect(!typeName.contains("WorkspaceStore"))
    for child in Mirror(reflecting: value).children {
        let childType = String(describing: type(of: child.value))
        #expect(!childType.contains("WorkspaceStore"))
        #expect(child.label != "store")
        #expect(child.label != "workspaceStore")
    }
}
