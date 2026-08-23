import Foundation

enum DecompositionPromptBuilder {
    static let instructions = """
你是 Jelly 的拆开助手，只根据用户给出的笔记来源回答。必须遵守以下约束：
- 需要追问时只问一个关键问题，并最多给 3 个简短快捷回答；无需追问时不要给问题或快捷回答
- 追问只问会改变行动阶段或范围的当前事实，例如已经做了什么、目标对象是否已经落实；不得询问先做哪一块、优先级、日程、开始时间、精确日期或总时长；已有且可原样保留的日期、金额、名称不要追问
- 初始 2～5 个候选行动
- 行动可独立完成
- 完成说明可观察
- 不得把父意图安排
- 只返回给定时长：15 / 30 / 45 / 60 / 90
- 不得覆盖标记为 locked 的字段
- 局部重拆不谈其他候选
- 中文输入用中文回答
不要创建日历、不要改写原文、不要输出领域命令。
"""

    static func clarification(_ request: ClarificationRequest) -> String {
        """
\(instructions)

任务：判断是否必须再问一个会改变拆法的问题。需要追问时只问一个关键问题，并最多给 3 个简短快捷回答；无需追问时不要给问题或快捷回答。
来源：
\(request.source.normalizedText)
"""
    }

    static func candidates(_ request: CandidateRequest) -> String {
        var lines = [
            instructions,
            "任务：根据来源和回答生成候选行动。初始 2～5。行动可独立完成。完成说明可观察。不得把父意图安排。只返回给定时长。不得覆盖标记为 locked 的字段。中文输入用中文回答。",
            "来源：",
            request.source.normalizedText
        ]
        if let answer = request.answer {
            lines.append("用户回答：\(answer)")
        }
        if !request.existingCandidates.isEmpty {
            lines.append("刷新时：每个现有 id 必须原样出现恰好一次；不得新增、省略、重复，也不得把 existingID 写成空或 null。locked 字段必须逐字保留。")
            lines.append("现有候选：")
            lines.append(contentsOf: request.existingCandidates.map(describe))
        }
        if let feedback = request.validationFeedback {
            lines.append("上次结构反馈：\(String(describing: feedback))")
        }
        return lines.joined(separator: "\n")
    }

    static func split(_ request: SplitCandidateRequest) -> String {
        var lines = [
            instructions,
            "任务：只重拆这一项。局部重拆不谈其他候选。行动可独立完成。完成说明可观察。不得把父意图安排。只返回给定时长。不得覆盖标记为 locked 的字段。中文输入用中文回答。",
            "来源：",
            request.source.normalizedText,
            "目标候选：",
            describe(request.target)
        ]
        if let answer = request.answer {
            lines.append("用户回答：\(answer)")
        }
        if let feedback = request.validationFeedback {
            lines.append("上次结构反馈：\(String(describing: feedback))")
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ candidate: PlannerCandidateContext) -> String {
        "id=\(candidate.id.uuidString) title=\(candidate.title) completion=\(candidate.completionDescription) minutes=\(candidate.estimatedMinutes) titleLockedByUser=\(candidate.titleLockedByUser) completionLockedByUser=\(candidate.completionLockedByUser)"
    }
}
