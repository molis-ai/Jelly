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
            "需要追问时只问一个关键问题，并最多给 3 个简短快捷回答；无需追问时不要给问题或快捷回答",
            "来源明确表示会改变行动范围的事实尚未确定时必须追问",
            "不得直接判断为无需追问",
            "错误快捷回答：先不确定。正确快捷回答：尚未确定",
            "初始 2～5",
            "行动可独立完成",
            "每个候选都必须基于当前来源立即开始",
            "不得依赖另一个候选先完成或假设其结果已经存在",
            "来源未说明候选对象已经存在时，不得安排查看、预约或比较这些对象",
            "错误：还没有候选房源时预约看房",
            "每个行动必须能在一次专注时段内完成",
            "不得把搜集、比较、决定、付款等多个阶段合成一项",
            "不得把签合同、付定金或下单设为完成标准",
            "不得新增来源和回答未提到的协作者、地点、承诺或截止日期",
            "不得把来源未提到的偏好、规格、房型、区域或服务类型变成筛选条件",
            "错误：来源没说整租却筛选整租房源",
            "不得复述这些规则或把列出待确认项、准备信息、制定计划当成行动",
            "不得用整理、处理、落实等模糊动词代替可直接执行的动作",
            "错误：整理当前可租房源。正确：筛选并保存 3 套符合已有截止日的房源",
            "错误：为找房列出需要确认的条件",
            "正确：筛选并保存 3 套符合已有截止日的房源",
            "金额、日期和名称必须保留来源中的作用范围",
            "范围不明确的金额只能保留为整体约束",
            "错误：把整体预算两万元改成月租两万元以内的房源条件",
            "整体预算是最终方案的总约束，不是多份备选报价的合计上限",
            "单个房源或搬家公司候选的标题和完成说明不得重复这个金额",
            "错误：两家搬家公司的报价合计不超过整体预算",
            "正确：筛选 3 套符合已有入住截止日的房源",
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
        #expect(prompt.contains("需要追问时只问一个关键问题，并最多给 3 个简短快捷回答；无需追问时不要给问题或快捷回答"))
        #expect(prompt.contains("最多给 3 个简短快捷回答"))
        #expect(prompt.contains("无需追问时不要给问题或快捷回答"))
        assertNoFrameworkLeak(prompt)
        assertNoFrameworkLeak(DecompositionPromptBuilder.instructions)
    }

    @Test func clarificationPromptAsksCurrentStateFactsNotWhichPartFirst() throws {
        let source = try makeSnapshot()
        let prompt = DecompositionPromptBuilder.clarification(
            ClarificationRequest(source: source)
        )
        let constraint = "追问只问会改变行动阶段或范围的当前事实，例如已经做了什么、目标对象是否已经落实；不得询问先做哪一块、优先级、日程、开始时间、精确日期或总时长；已有且可原样保留的日期、金额、名称不要追问"
        let removed = "追问只用于决定需要哪些候选行动；不得询问日程、开始时间、精确日期、总时长或优先级；已有且可原样保留的日期、金额、名称不要追问"
        let directFactContract = "若有多个未知事实，你自行选择最影响行动范围的一项直接询问，不得让用户先选择想理清哪个或从哪一块开始；快捷回答只能描述事实状态，不描述偏好或先后顺序"
        let requiredClarificationContract = "来源明确表示会改变行动范围的事实尚未确定时必须追问，不得直接判断为无需追问"
        let badExample = "错误：你更想先理清入住日期还是预算？"
        let goodExample = "正确：入住日期目前确定了吗？"
        let quickAnswerExample = "错误快捷回答：先不确定。正确快捷回答：尚未确定"
        #expect(
            DecompositionPromptBuilder.instructions.contains(constraint),
            "缺少约束：\(constraint)"
        )
        #expect(prompt.contains(constraint), "缺少约束：\(constraint)")
        #expect(DecompositionPromptBuilder.instructions.contains(directFactContract))
        #expect(prompt.contains(directFactContract))
        #expect(DecompositionPromptBuilder.instructions.contains(requiredClarificationContract))
        #expect(prompt.contains(requiredClarificationContract))
        #expect(DecompositionPromptBuilder.instructions.contains(badExample))
        #expect(prompt.contains(badExample))
        #expect(DecompositionPromptBuilder.instructions.contains(goodExample))
        #expect(prompt.contains(goodExample))
        #expect(DecompositionPromptBuilder.instructions.contains(quickAnswerExample))
        #expect(prompt.contains(quickAnswerExample))
        #expect(!DecompositionPromptBuilder.instructions.contains(removed), "旧弱约束仍在 instructions")
        #expect(!prompt.contains(removed), "旧弱约束仍在 clarification prompt")
        #expect(!DecompositionPromptBuilder.instructions.contains("需要哪些候选行动"))
        #expect(!prompt.contains("需要哪些候选行动"))
        #expect(!DecompositionPromptBuilder.instructions.contains("边界、数量或顺序"))
        #expect(!prompt.contains("边界、数量或顺序"))
        #expect(DecompositionPromptBuilder.instructions.contains("需要追问时只问一个关键问题，并最多给 3 个简短快捷回答；无需追问时不要给问题或快捷回答"))
        #expect(prompt.contains("最多给 3 个简短快捷回答"))
        #expect(prompt.contains("无需追问时不要给问题或快捷回答"))
        #expect(!DecompositionPromptBuilder.instructions.contains("只问一个关键问题或明确无需追问"))
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
        #expect(prompt.contains("completionDescription=拿到明确上门时间"))
        #expect(!prompt.contains(" completion=拿到明确上门时间"))
        #expect(prompt.contains("titleLockedByUser=true"))
        #expect(prompt.contains("不得覆盖标记为 locked 的字段"))
        #expect(prompt.contains("刷新时只返回这 1 个现有候选，总数必须恰好为 1"))
        #expect(prompt.contains("至少一个未锁定字段必须返回新的改进内容，不得把全部未锁定字段原样照抄"))
        #expect(prompt.contains("只返回给定时长"))
        #expect(prompt.contains("15 / 30 / 45 / 60 / 90"))
        #expect(prompt.contains("初始 2～5"))
        #expect(prompt.contains("每个候选都必须基于当前来源立即开始"))
        #expect(prompt.contains("不得依赖另一个候选先完成或假设其结果已经存在"))
        #expect(prompt.contains("来源未说明候选对象已经存在时，不得安排查看、预约或比较这些对象"))
        #expect(prompt.contains("错误：还没有候选房源时预约看房"))
        #expect(prompt.contains("错误：还没有报价时比较两份报价"))
        #expect(prompt.contains("正确：联系 2 家搬家公司获取书面报价"))
        #expect(prompt.contains("每个行动必须能在一次专注时段内完成"))
        #expect(prompt.contains("不得把搜集、比较、决定、付款等多个阶段合成一项"))
        #expect(prompt.contains("来源没有明确说明用户已经准备承诺时，不得把签合同、付定金或下单设为完成标准"))
        #expect(prompt.contains("不得新增来源和回答未提到的协作者、地点、承诺或截止日期"))
        #expect(prompt.contains("不得把来源未提到的偏好、规格、房型、区域或服务类型变成筛选条件"))
        #expect(prompt.contains("错误：来源没说整租却筛选整租房源"))
        #expect(prompt.contains("可以给出 2～3 个这类有限数量作为本次行动的可验证产物"))
        #expect(prompt.contains("不得复述这些规则或把列出待确认项、准备信息、制定计划当成行动"))
        #expect(prompt.contains("不得用整理、处理、落实等模糊动词代替可直接执行的动作"))
        #expect(prompt.contains("错误：为找房列出需要确认的条件"))
        #expect(prompt.contains("正确：联系 2 家搬家公司获取书面报价"))
        #expect(prompt.contains("金额、日期和名称必须保留来源中的作用范围"))
        #expect(prompt.contains("范围不明确的金额只能保留为整体约束"))
        #expect(prompt.contains("不得拿去筛选单个房源、报价或其他子项"))
        #expect(prompt.contains("错误：把整体预算两万元改成月租两万元以内的房源条件"))
        #expect(prompt.contains("错误：把整体预算两万元改成搬家公司报价两万元以内"))
        #expect(prompt.contains("整体预算是最终方案的总约束，不是多份备选报价的合计上限"))
        #expect(prompt.contains("单个房源或搬家公司候选的标题和完成说明不得重复这个金额"))
        #expect(prompt.contains("错误：两家搬家公司的报价合计不超过整体预算"))
        #expect(prompt.contains("修复上次结构错误时仍须遵守全部事实和行动约束"))
        #expect(prompt.contains("不得为了修复数量、时长或 id 而重新解释来源"))
        assertNoFrameworkLeak(prompt)
    }

    @Test func candidatePromptStatesRefreshIDSetInvariantWhenExistingCandidatesArePresent() throws {
        let source = try makeSnapshot()
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000402")!
        let refreshContract = "刷新时：每个现有 id 必须原样出现恰好一次；不得新增、省略、重复，也不得把 existingID 写成空或 null。locked 字段必须逐字保留。"

        let refresh = DecompositionPromptBuilder.candidates(
            CandidateRequest(
                source: source,
                answer: "拿到确认",
                existingCandidates: [
                    PlannerCandidateContext(
                        id: firstID,
                        title: "给物业打电话",
                        completionDescription: "拿到明确上门时间",
                        estimatedMinutes: 30,
                        titleLockedByUser: true,
                        completionLockedByUser: false
                    ),
                    PlannerCandidateContext(
                        id: secondID,
                        title: "记录上门时间",
                        completionDescription: "把确认写进笔记",
                        estimatedMinutes: 15,
                        titleLockedByUser: false,
                        completionLockedByUser: true
                    )
                ],
                validationFeedback: nil
            )
        )
        #expect(refresh.contains(firstID.uuidString))
        #expect(refresh.contains(secondID.uuidString))
        #expect(refresh.contains("titleLockedByUser=true"))
        #expect(refresh.contains("completionLockedByUser=true"))
        #expect(refresh.contains(refreshContract), "缺少刷新 ID 集合约束：\(refreshContract)")
        #expect(refresh.contains("刷新时只返回这 2 个现有候选，总数必须恰好为 2"))
        #expect(refresh.contains("至少一个未锁定字段必须返回新的改进内容，不得把全部未锁定字段原样照抄"))
        #expect(refresh.contains("不得覆盖标记为 locked 的字段"))
        assertNoFrameworkLeak(refresh)

        let initial = DecompositionPromptBuilder.candidates(
            CandidateRequest(
                source: source,
                answer: "拿到确认",
                existingCandidates: [],
                validationFeedback: nil
            )
        )
        #expect(!initial.contains(refreshContract))
        #expect(!initial.contains("刷新时只返回这 0 个现有候选"))
        #expect(!initial.contains("每个现有 id 必须原样出现恰好一次"))
        assertNoFrameworkLeak(initial)
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
        #expect(prompt.contains("局部重拆必须返回 2～5 个比目标候选更小、可独立开始的行动"))
        #expect(prompt.contains("两项已经覆盖目标时只返回两项"))
        #expect(prompt.contains("不得为凑数量添加依赖前项产物的后续行动"))
        #expect(prompt.contains("局部重拆仍须遵守整体预算不得写入单个房源或搬家公司候选的约束"))
        #expect(prompt.contains("房源或搬家公司候选的标题与完成说明禁止出现两万元、2 万或 20000"))
        #expect(prompt.contains("如需处理整体预算，只能单独生成预算分配行动"))
        #expect(prompt.contains("中文输入用中文回答"))
        #expect(prompt.contains("行动可独立完成"))
        #expect(prompt.contains("每个行动必须能在一次专注时段内完成"))
        #expect(prompt.contains("不得把搜集、比较、决定、付款等多个阶段合成一项"))
        #expect(prompt.contains("来源没有明确说明用户已经准备承诺时，不得把签合同、付定金或下单设为完成标准"))
        #expect(prompt.contains("不得把来源未提到的偏好、规格、房型、区域或服务类型变成筛选条件"))
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
