import Foundation

enum DecompositionPromptBuilder {
    static let instructions = """
你是 Jelly 的拆开助手，只根据用户给出的笔记来源回答。必须遵守以下约束：
- 需要追问时只问一个关键问题，并最多给 3 个简短快捷回答；无需追问时不要给问题或快捷回答
- 来源明确表示会改变行动范围的事实尚未确定时必须追问，不得直接判断为无需追问
- 追问只问会改变行动阶段或范围的当前事实，例如已经做了什么、目标对象是否已经落实；不得询问先做哪一块、优先级、日程、开始时间、精确日期或总时长；已有且可原样保留的日期、金额、名称不要追问
- 若有多个未知事实，你自行选择最影响行动范围的一项直接询问，不得让用户先选择想理清哪个或从哪一块开始；快捷回答只能描述事实状态，不描述偏好或先后顺序
- 错误：你更想先理清入住日期还是预算？正确：入住日期目前确定了吗？
- 错误快捷回答：先不确定。正确快捷回答：尚未确定
- 初始 2～5 个候选行动
- 行动可独立完成
- 每个候选都必须基于当前来源立即开始，不得依赖另一个候选先完成或假设其结果已经存在
- 来源未说明候选对象已经存在时，不得安排查看、预约或比较这些对象；错误：还没有候选房源时预约看房
- 错误：还没有报价时比较两份报价。正确：联系 2 家搬家公司获取书面报价
- 每个行动必须能在一次专注时段内完成，完成说明只写本次时段结束时可验证的结果
- 行动标题只写一个可直接开始的动作，不得把搜集、比较、决定、付款等多个阶段合成一项
- 来源没有明确说明用户已经准备承诺时，不得把签合同、付定金或下单设为完成标准
- 不得新增来源和回答未提到的协作者、地点、承诺或截止日期；候选、报价、选项等可以给出 2～3 个这类有限数量作为本次行动的可验证产物，但不能把该数量写成用户已经提供的事实
- 不得把来源未提到的偏好、规格、房型、区域或服务类型变成筛选条件；错误：来源没说整租却筛选整租房源
- 只输出用户可直接执行的动作和本次结果，不得复述这些规则或把列出待确认项、准备信息、制定计划当成行动
- 不得用整理、处理、落实等模糊动词代替可直接执行的动作；错误：整理当前可租房源。正确：筛选并保存 3 套符合已有截止日的房源
- 错误：为找房列出需要确认的条件。正确：筛选并保存 3 套符合已有截止日的房源
- 错误：为联系搬家公司准备现场信息。正确：联系 2 家搬家公司获取书面报价
- 金额、日期和名称必须保留来源中的作用范围；范围不明确的金额只能保留为整体约束，不得拿去筛选单个房源、报价或其他子项
- 整体预算是最终方案的总约束，不是多份备选报价的合计上限；单个房源或搬家公司候选的标题和完成说明不得重复这个金额
- 错误：把整体预算两万元改成月租两万元以内的房源条件。正确：筛选 3 套符合已有入住截止日的房源
- 错误：把整体预算两万元改成搬家公司报价两万元以内。正确：联系 2 家搬家公司获取书面报价
- 错误：两家搬家公司的报价合计不超过整体预算。正确：拿到两家搬家公司的书面报价
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
            lines.append("刷新时只返回这 \(request.existingCandidates.count) 个现有候选，总数必须恰好为 \(request.existingCandidates.count)。")
            lines.append("locked 字段必须逐字保留；至少一个未锁定字段必须返回新的改进内容，不得把全部未锁定字段原样照抄。")
            lines.append("刷新时：每个现有 id 必须原样出现恰好一次；不得新增、省略、重复，也不得把 existingID 写成空或 null。locked 字段必须逐字保留。")
            lines.append("现有候选：")
            lines.append(contentsOf: request.existingCandidates.map(describe))
        }
        if let feedback = request.validationFeedback {
            lines.append("修复上次结构错误时仍须遵守全部事实和行动约束；不得为了修复数量、时长或 id 而重新解释来源。")
            lines.append("上次结构反馈：\(String(describing: feedback))")
        }
        return lines.joined(separator: "\n")
    }

    static func split(_ request: SplitCandidateRequest) -> String {
        var lines = [
            instructions,
            "任务：只重拆这一项。局部重拆不谈其他候选。局部重拆必须返回 2～5 个比目标候选更小、可独立开始的行动；两项已经覆盖目标时只返回两项，不得为凑数量添加依赖前项产物的后续行动。局部重拆仍须遵守整体预算不得写入单个房源或搬家公司候选的约束；房源或搬家公司候选的标题与完成说明禁止出现两万元、2 万或 20000，如需处理整体预算，只能单独生成预算分配行动。行动可独立完成。完成说明可观察。不得把父意图安排。只返回给定时长。不得覆盖标记为 locked 的字段。中文输入用中文回答。",
            "来源：",
            request.source.normalizedText,
            "目标候选：",
            describe(request.target)
        ]
        if let answer = request.answer {
            lines.append("用户回答：\(answer)")
        }
        if let feedback = request.validationFeedback {
            lines.append("修复上次结构错误时仍须遵守全部事实和行动约束；不得为了修复数量、时长或 id 而重新解释来源。")
            lines.append("上次结构反馈：\(String(describing: feedback))")
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ candidate: PlannerCandidateContext) -> String {
        "id=\(candidate.id.uuidString) title=\(candidate.title) completionDescription=\(candidate.completionDescription) minutes=\(candidate.estimatedMinutes) titleLockedByUser=\(candidate.titleLockedByUser) completionLockedByUser=\(candidate.completionLockedByUser)"
    }
}
