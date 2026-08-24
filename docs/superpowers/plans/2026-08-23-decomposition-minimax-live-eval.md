# MiniMax-M3 拆解质量真实回归 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用 appkey 中的 MiniMax-M3 真实调用复用 Jelly production prompt 与 validator，建立可重复、不会进入生产 App 的中文拆解质量回归。

**Architecture:** 所有 HTTP、鉴权、Anthropic Messages envelope 和 JSON text 解析只存在于 `CalendarAppTests` 与一个 shell runner。普通测试使用注入 transport 做离线解析回归；live suite 只有 `JELLY_MINIMAX_LIVE=1` 才发请求，响应随后进入真实 `DecompositionOutputValidator` / `DecompositionDraftReducer`。

**Tech Stack:** Swift 6.3、Foundation `URLSession`、Swift Testing、POSIX shell、appkey、MiniMax Anthropic-compatible Messages API。

**Spec:** `docs/superpowers/specs/2026-08-23-plan-and-schedule-nine-point-hardening-design.md`

## Global Constraints

- 钥匙只通过 `appkey exec minimax -- ...` 同一条 shell 注入；不得读取 `~/.appkey/` 或单独执行 `appkey get`。
- 不得把 key、Authorization header、完整环境或 appkey 内部文件写入日志、fixture、源代码或 commit。
- 默认模型 `MiniMax-M3`；默认 base URL `https://api.minimaxi.com/anthropic`。
- MiniMax client、response DTO 和 JSON contract 只在 `Tests/CalendarAppTests`。
- 普通 `swift test` 在无 appkey、无网络时必须通过且不得尝试网络。
- MiniMax 通过不等于 Apple Foundation Models 产品实操通过。
- Live 输出可以显示案例名、模型、耗时和候选正文，不得显示 header 或 key。

---

### Task 1: 建立测试专用 Anthropic Messages client 和安全解析

**Files:**
- Create: `Tests/CalendarAppTests/MiniMaxDecompositionLiveTestSupport.swift`
- Create: `Tests/CalendarAppTests/MiniMaxDecompositionLiveSupportTests.swift`

**Interfaces:**
- Produces: `MiniMaxLiveConfiguration`
- Produces: `MiniMaxMessagesTransport`
- Produces: `MiniMaxLiveClient.text(system:prompt:) async throws -> String`
- Produces: `MiniMaxResponseDecoder.decodeClarification(_:)`
- Produces: `MiniMaxResponseDecoder.decodeActions(_:)`

- [ ] **Step 1: 写离线 response 解析失败测试**

覆盖纯 JSON、markdown fence、缺少 text block、HTTP error、非 JSON 正文和无效 existing ID：

```swift
@Test func decoderAcceptsPlainAndFencedClarificationJSON() throws {
    let plain = #"{"needsFollowUp":true,"question":"最晚什么时候完成？","quickAnswers":["本周","下周"]}"#
    let fenced = "```json\n\(plain)\n```"
    #expect(try MiniMaxResponseDecoder.decodeClarification(plain).needsFollowUp)
    #expect(try MiniMaxResponseDecoder.decodeClarification(fenced).quickAnswers.count == 2)
}

@Test func decoderMapsActionsToProductionPlannerCandidates() throws {
    let text = #"{"actions":[{"existingID":null,"title":"联系诊所","completionDescription":"拿到可预约时间","estimatedMinutes":15}]}"#
    let actions = try MiniMaxResponseDecoder.decodeActions(text)
    #expect(actions[0].title == "联系诊所")
    #expect(actions[0].existingID == nil)
}
```

- [ ] **Step 2: 运行 support tests 确认 RED**

```bash
swift test --filter MiniMaxDecompositionLiveSupportTests
```

Expected: FAIL，support types 不存在。

- [ ] **Step 3: 实现最小 Codable DTO 和 decoder**

Test-only response types：

```swift
private struct ClarificationPayload: Decodable {
    let needsFollowUp: Bool
    let question: String
    let quickAnswers: [String]
}

private struct ActionListPayload: Decodable {
    let actions: [ActionPayload]
}

private struct ActionPayload: Decodable {
    let existingID: String?
    let title: String
    let completionDescription: String
    let estimatedMinutes: Int
}
```

Decoder 只去掉首尾空白和一层 ```json fence；不做字段补全、不修标题、不替换非法时长。UUID 无效时抛错，让真实结构问题暴露。

- [ ] **Step 4: 写 client transport 失败测试**

定义可注入 transport：

```swift
protocol MiniMaxMessagesTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
```

用 scripted transport 断言：URL 为 `<base>/v1/messages`、model 正确、system/prompt 分开、header 有 `Authorization: Bearer <injected-test-value>`，但 client error description 不包含该值；2xx 提取全部 text blocks，非 2xx 只返回 status 与安全 error message。

- [ ] **Step 5: 实现 ephemeral live transport**

`MiniMaxLiveConfiguration.fromEnvironment()` 只读取：

- `MINIMAX_API_KEY`（required only in live mode）
- `JELLY_MINIMAX_BASE_URL`（default domestic URL）
- `JELLY_MINIMAX_MODEL`（default MiniMax-M3）

Live transport 使用 `URLSessionConfiguration.ephemeral`，request/resource timeout 30/45 秒。不得打印 request headers。

- [ ] **Step 6: 运行 support tests**

```bash
swift test --filter MiniMaxDecompositionLiveSupportTests
```

Expected: PASS，且没有网络调用。

- [ ] **Step 7: 提交 Task 1**

```bash
git add Tests/CalendarAppTests/MiniMaxDecompositionLiveTestSupport.swift Tests/CalendarAppTests/MiniMaxDecompositionLiveSupportTests.swift
git commit -m "test(拆解): 添加 MiniMax 测试客户端"
```

---

### Task 2: 用 production prompt 和 validator 建立固定中文 live suite

**Files:**
- Create: `Tests/CalendarAppTests/MiniMaxDecompositionLiveTests.swift`
- Modify: `Tests/CalendarAppTests/MiniMaxDecompositionLiveTestSupport.swift`

**Interfaces:**
- Consumes: `DecompositionPromptBuilder`
- Consumes: `DecompositionOutputValidator`
- Consumes: `DecompositionDraftReducer`
- Produces: `MiniMaxDecompositionLiveTests`

- [ ] **Step 1: 定义与 Apple schema 等价的 test-only response contract**

在 support 中固定：

```swift
enum MiniMaxJSONContract {
    static let clarification = """
只返回一个 JSON 对象，不要 Markdown：
{"needsFollowUp":true或false,"question":"字符串；无需追问时为空","quickAnswers":["最多3个简短回答"]}
"""

    static let actions = """
只返回一个 JSON 对象，不要 Markdown：
{"actions":[{"existingID":null或现有UUID字符串,"title":"行动标题","completionDescription":"可观察的完成说明","estimatedMinutes":15或30或45或60或90}]}
"""
}
```

Contract 只规定结构，不替换 `DecompositionPromptBuilder` 的产品约束。

- [ ] **Step 2: 写 gated suite 骨架并证明普通测试不联网**

```swift
@Suite("MiniMaxDecompositionLiveTests", .serialized)
struct MiniMaxDecompositionLiveTests {
    private var liveEnabled: Bool {
        ProcessInfo.processInfo.environment["JELLY_MINIMAX_LIVE"] == "1"
    }

    @Test func fixedChineseJourneyPassesProductionContracts() async throws {
        guard liveEnabled else { return }
        // real calls
    }
}
```

在 support test 注入 transport counter，普通 `swift test --filter MiniMaxDecompositionLiveTests` 时断言没有构造 live client 或发送 request。若 Swift Testing trait 能在当前 pinned revision 明确报告 disabled，可改用 `.enabled(if:)`；否则保留 guard，不能引入版本不兼容 API。

- [ ] **Step 3: 实现模糊与具体来源的 clarification 回归**

固定来源：

```text
模糊：我想把搬家这件事搞定，但入住日期和预算都还没确定。
具体：今天下午四点前给牙科诊所打电话，预约下周三上午检查，拿到确认短信后把时间记下来。
```

模糊来源期望：`needsFollowUp == true`、question 非空、quickAnswers `<= 3`。具体来源期望：`needsFollowUp == false`、question trim 后为空。两次都使用 `DecompositionPromptBuilder.clarification`。

- [ ] **Step 4: 实现初始拆解与 locked refresh 回归**

初始拆解把回答「9 月 15 日前搬完，预算两万元，先确定房子和搬家公司」传入 production candidate prompt，响应进入：

```swift
let validated = try DecompositionOutputValidator.validateInitial(decoded)
#expect((2...5).contains(validated.count))
```

Locked refresh 使用两个固定 UUID，第一项 title locked、第二项 completion locked；MiniMax 响应先 `validateRefresh`，再 `mergeRefresh`，断言人工字段逐字保留，所有 ID 各出现一次。

- [ ] **Step 5: 实现局部重拆与 validation feedback 回归**

目标「准备搬家」带具体完成说明。split 响应必须 `validateSplit`，所有 `existingID == nil`，2～5 项。修复请求把 `.invalidDuration(index: 0, minutes: 20)` 放入 production prompt，响应必须通过真实 validator；不得在 decoder 中把 20 改成 15/30。

- [ ] **Step 6: 输出安全的人类复审记录**

每个案例打印一行：

```text
[MiniMax-M3] case=initial status=PASS latency_ms=1234 count=3
  1. 联系搬家公司｜拿到书面报价｜30
```

不打印 key、Authorization、全部 env、raw HTTP headers。HTTP 错误只打印 status、provider error type/message（截断 300 字符）。

- [ ] **Step 7: 运行普通测试证明不需要 key**

```bash
env -u MINIMAX_API_KEY -u JELLY_MINIMAX_LIVE swift test --filter MiniMaxDecompositionLive
```

Expected: PASS；network transport send count 为 0。

- [ ] **Step 8: 提交 Task 2**

```bash
git add Tests/CalendarAppTests/MiniMaxDecompositionLiveTests.swift Tests/CalendarAppTests/MiniMaxDecompositionLiveTestSupport.swift
git commit -m "test(拆解): 固化 MiniMax 中文回归"
```

---

### Task 3: 添加 appkey runner 并真实运行 MiniMax-M3

**Files:**
- Create: `Scripts/test-decomposition-minimax-live.sh`
- Modify: `docs/qa/2026-08-22-plan-and-schedule-product-run.md`

**Interfaces:**
- Consumes: appkey name `minimax`
- Sets: `JELLY_MINIMAX_LIVE=1`
- Sets: `JELLY_MINIMAX_BASE_URL=https://api.minimaxi.com/anthropic`
- Sets: `JELLY_MINIMAX_MODEL=MiniMax-M3`

- [ ] **Step 1: 写 runner 自检模式**

脚本使用 `set -eu`，支持 `--self-test`。Self-test 注入一个临时 fake appkey executable，证明：

- 先执行 `list`。
- 找到 `minimax` 后使用一次 `exec minimax -- env ... swift test ...`。
- list 不含 minimax 时退出非 0 且只提示 `appkey set minimax --env MINIMAX_API_KEY --prompt`，不要求粘贴 key。
- 输出不包含 fake secret。

- [ ] **Step 2: 实现 PATH / fallback 选择**

核心结构：

```sh
if command -v appkey >/dev/null 2>&1; then
  appkey_cmd=appkey
else
  appkey_cmd="python3 /Users/oreal/.grok/skills/appkey/scripts/appkey"
fi
```

因为 fallback 包含两个 argv，不得直接未引用执行字符串；实现一个 `run_appkey()` 函数分别分支调用。先 `list` 验证 name，再在同一脚本进程中：

```sh
run_appkey exec minimax -- env \
  JELLY_MINIMAX_LIVE=1 \
  JELLY_MINIMAX_BASE_URL=https://api.minimaxi.com/anthropic \
  JELLY_MINIMAX_MODEL=MiniMax-M3 \
  swift test --filter MiniMaxDecompositionLiveTests
```

- [ ] **Step 3: 运行 self-test 与 shell 语法检查**

```bash
sh -n Scripts/test-decomposition-minimax-live.sh
sh Scripts/test-decomposition-minimax-live.sh --self-test
```

Expected: PASS；stdout/stderr 无 fake secret。

- [ ] **Step 4: 让脚本可执行并真实调用**

```bash
chmod +x Scripts/test-decomposition-minimax-live.sh
./Scripts/test-decomposition-minimax-live.sh
```

Expected: appkey 使用 `minimax`，MiniMax-M3 固定中文 suite 全部通过或给出具体结构/质量失败；不得为了绿测重跑直到偶然成功。首次真实结果原样进入缺陷分析。

- [ ] **Step 5: Codex 独立做语义复审**

逐个读输出，按以下规则打 PASS/FAIL：

- 问题会改变拆法，不是机械复述。
- 具体来源不机械追问。
- 每个标题能直接行动，不是父意图。
- 完成说明是可观察结果，不是同义改写。
- locked 字段逐字保留。
- split 只谈目标候选。
- 修复请求没有继续返回非法时长或数量。

结构通过但语义失败时，先给 `DecompositionPromptBuilder` 写失败 contract test，再最小修 prompt；不得在 test-only contract 偷加产品语义把 production prompt 的缺口遮住。

- [ ] **Step 6: 更新 QA 证据边界**

记录模型、base URL、运行日期、案例结果和真实输出摘要。结论固定写：

```text
MiniMax-M3 真实 LLM 调用与 Jelly production prompt/validator 回归：PASS/FAIL。
该证据不代表 Apple Foundation Models 在最终 App 中可用或质量通过。
```

- [ ] **Step 7: 提交 Task 3**

```bash
git add Scripts/test-decomposition-minimax-live.sh docs/qa/2026-08-22-plan-and-schedule-product-run.md
git commit -m "test(拆解): 接入 MiniMax 真实回归"
```

---

## Plan Self-Review

- Spec coverage: key 注入、国内 base、默认模型、test-only client、production prompt、真实 validator、6 类中文案例、安全输出和证据边界均有任务。
- Provider boundary: `Sources` 与 `Package.swift` 不修改；MiniMax 只在 Tests、Scripts、QA。
- Type consistency: client、transport、configuration、decoder 和 suite 名称在首次定义后保持一致。
- Placeholder scan: 无 TBD/TODO；每个失败、调用、结构与人工复审条件均明确。

## Execution Handoff

本计划由 Grok 在 UI hardening Tasks 1–5 可并行的独立测试轨上实施，但提交仍保持单一线性历史。Codex 复审 test-only 边界、secret hygiene、真实调用输出和语义质量；agent 报告不能替代 Codex 直接运行 `./Scripts/test-decomposition-minimax-live.sh`。
