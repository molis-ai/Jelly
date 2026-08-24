# Jelly 灵感材料提炼 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 本计划由一个 Grok Worker 连续执行；每个 Task 保留独立 RED/GREEN 证据和候选提交，全部完成后交 Codex 统一 review，不自行合并、推送、发布或宣称用户验收通过。

**Goal:** 在 Jelly 的灵感详情中交付 B 站视频与小宇宙单集的“手动提炼 → 审阅 → 保留原链接写入笔记”完整真实旅程，并把等待、取消、失败、重试、重启恢复和本机资源边界做到用户 9 分体验。

**Architecture:** 原始 `Inspiration` 保持 raw-first；新增独立 `MaterialDigest` 领域对象和 runID/checksum 状态机。App 层的 `MaterialDigestCoordinator` 组合来源解析、本机 WhisperKit 识别与 OpenAI 兼容结构化摘要，所有持久状态仍通过 Workspace Reducer 写入；视图只呈现状态和发出用户动作。

**Tech Stack:** Swift 6.3、SwiftUI、Foundation/URLSession、Security/Keychain、AVFoundation、swift-testing、macOS 14+、Apple silicon、Argmax OSS Swift Package `1.0.0` 的 `WhisperKit` 产品、JSON 本地持久化 schema V4 可选扩展。

> **Codex review 修订（2026-08-22）：** 本计划后文保留 Grok 当时的逐步执行记录，但最终候选的审查修订优先于原计划：持久化不升 V5，而是在 V4 中增加可选派生 Digest 以保住旧版回滚读取原始链接/笔记；401 与 403 分别呈现密钥错误和模型权限错误；来源请求采用有上限的流式读取、逐跳 SSRF 校验，并兼容系统代理的 fake-IP 模式；写入提交不确定时保留原灵感和精确事务令牌，不静默成功；写入后的 V4 文档必须能重新解码，且回执只能持有笔记内真实存在的摘要块；隔离验收目录同时隔离 Workspace、Whisper 模型、Keychain 服务和 endpoint/model 偏好，不能触碰正式 Jelly 配置。旧版 Jelly 回写会丢派生 Digest，这不是无损双向兼容，正式升级前仍需备份。

**Spec:** `docs/superpowers/specs/2026-08-22-inspiration-material-digest-design.md`

## Global Constraints

- 用户界面只写中文；产品中统一称“灵感”，按钮使用“提炼这个链接”“取消”“重试”“写入笔记”。
- 捕获必须立即落盘，不得等待元数据、字幕、音频、WhisperKit 或摘要模型。
- 仅支持 B 站视频页和小宇宙单集页；节目首页、B 站专栏/空间、文章、文件保持不支持语义。
- 不读取或要求 B 站/小宇宙 Cookie，不绕过权限，不使用 `yt-dlp`、Python venv、Homebrew CLI 或外部常驻服务。
- 音视频只在本机处理，不上传到 Jelly 自有服务器；模型密钥只存系统 Keychain。
- WhisperKit 固定依赖 `https://github.com/argmaxinc/argmax-oss-swift.git` exact `1.0.0`，第一版模型固定 `large-v3-v20240930_626MB`。
- 首次模型下载约 626 MB，只有确定需要本机识别时才提示并等待用户确认；有可用字幕时不得下载模型。
- 摘要使用用户配置的 OpenAI 兼容 `/chat/completions` 接口；先请求 `json_schema`，端点明确不支持时提示用户，不自动降级成不可校验自由文本。
- 摘要、字幕、模型信息不得写入 `Inspiration.rawText`、`rawURL` 或 `resolvedMetadata`。
- 所有 Digest 持久变化必须走 WorkspaceCommand → Reducer → Validator → Repository；视图不得直接改字典。
- runID、sourceChecksum 或当前阶段不匹配的迟到结果必须 no-change，不能覆盖新运行。
- 重试保留上次成功结果，只有新运行完整成功才原子替换；失败、取消或中断不伤原始灵感和已有结果。
- 不把 fixture、假摘要或测试 Provider 接入生产默认路径。
- Grok Worker 不触碰原始 `main` 工作区的日历/周视图改动，只在本分支工作。
- 每个 Task 严格 RED → 观察预期失败 → 最小 GREEN → focused tests → diff check → 候选提交。
- 工程绿不等于产品实操或用户验收；真人摘要质量、等待感受和本机资源手感在用户确认前保持 `UNVERIFIED`。

## 用户 9 分体验闸门

这里的“9 分”是实现和 review 的目标，不是团队替用户打分。Codex 最终用下面 10 项做打包 App 实操：至少 9 项通过，且任何硬失败都不能用其它分数抵消；用户本人没有实际认可前，仍只能写“用户验收 `UNVERIFIED`”。

1. 粘贴后一次操作就保存，立即看到原链接与“已保存”反馈；断网也不丢，重启后仍在。
2. 捕获过程不弹摘要确认框、不偷偷下载模型、不偷偷消耗摘要额度。
3. 支持来源只出现一个清楚的主操作“提炼这个链接”；普通文章、节目首页和 B 站非视频页不出现假能力。
4. 点击、取消、重试在 300 ms 内出现可见反馈；长任务始终显示准确阶段，不用模糊“处理中”掩盖等待。
5. 有合格字幕时直接进入摘要，不下载 626 MB 模型；确实需要识别时先说明体积并等待“下载并继续”。
6. 切页、取消、失败、重试和重启后的状态都诚实；迟到结果不能回写，旧成功结果不能被失败重试抹掉。
7. 受限、下线、错误配置和非法模型输出都有能行动的中文说明；原链接始终可复制、可打开、可恢复。
8. 成功结果结构完整且可审阅：核心论点、3～7 条观点、时间章节、可选引用、dropped 和折叠文稿；没有占位摘要。
9. “写入笔记”再次由用户确认，原链接排第一，摘要结构可继续编辑，重复点击不创建第二篇；提交结果不确定时必须原地显示“继续确认写入”，用原事务令牌恢复，不能静默或假成功。
10. 最终包不含用户密钥、真实音频、Whisper 模型或外部 CLI；连续处理代表性材料后界面仍响应，空闲时不持续做重活。

硬失败包括：丢原链接、无确认写笔记、写入结果不确定却静默或假成功、无确认下载大模型、假成功/占位摘要、取消后回写、密钥落盘到 Workspace/日志、生产接入 fixture、旧数据迁移损坏。任何一项出现，候选都不能进入用户验收。

## File Map

### Domain

- Create `Sources/WorkspaceDomain/MaterialDigest.swift`: Digest、运行、文稿、摘要、失败和 provenance 纯领域类型。
- Modify `Sources/WorkspaceDomain/WorkspaceIDs.swift`: `MaterialDigestID`、`MaterialDigestRunID`。
- Modify `Sources/WorkspaceDomain/WorkspaceState.swift`: `materialDigests` 1:1 集合。
- Modify `Sources/WorkspaceDomain/WorkspaceCommand.swift`: Digest payload、命令、no-change 与 reducer error。
- Create `Sources/WorkspaceDomain/WorkspaceReducer+MaterialDigest.swift`: Digest 状态机。
- Modify `Sources/WorkspaceDomain/WorkspaceReducer.swift`: 命令路由、业务等价、恢复校验。
- Modify `Sources/WorkspaceDomain/WorkspaceReducer+Inspiration.swift`: 永久删除时移除 Digest；转换笔记仍由候选 Note 合同约束。
- Modify `Sources/WorkspaceDomain/WorkspaceValidator.swift`: Digest 引用、checksum、结果合同与阶段校验。
- Modify `Sources/WorkspaceDomain/WorkspaceContentSnapshot.swift`: 备份/恢复包含 Digest。

### Persistence

- Modify `Sources/CalendarPersistence/WorkspaceDocument.swift`: schema 4 → 5；新增私有 V3/V4 DTO。
- Modify `Sources/CalendarPersistence/WorkspaceDocumentCodec.swift`: 显式 V3/V4 → V5 迁移、V5 编解码和确定性排序。

### App services

- Create `Sources/CalendarApp/Inspiration/SourceKindClassifier.swift`: 纯域名/路径分类。
- Modify `Sources/CalendarApp/Inspiration/URLMetadataResolver.swift`: 分类优先和失败安全。
- Create `Sources/CalendarApp/Inspiration/MaterialDigestProtocols.swift`: App 层端口与候选类型。
- Create `Sources/CalendarApp/Inspiration/MaterialDigestCoordinator.swift`: 运行编排、取消、重启恢复和写回。
- Create `Sources/CalendarApp/Inspiration/MaterialSourceProviders.swift`: B 站和小宇宙获取器、受限下载、临时文件。
- Create `Sources/CalendarApp/Inspiration/WhisperKitMaterialTranscriber.swift`: 模型准备、下载、识别和时间戳映射。
- Create `Sources/CalendarApp/Inspiration/OpenAICompatibleMaterialSummarizer.swift`: JSON Schema 请求、响应解码和本地校验。
- Create `Sources/CalendarApp/Inspiration/DigestCredentialStore.swift`: Keychain 密钥。
- Create `Sources/CalendarApp/Inspiration/DigestSettingsStore.swift`: endpoint/model 非敏感偏好。
- Create `Sources/CalendarApp/Inspiration/DigestSettingsView.swift`: App 设置界面。
- Create `Sources/CalendarApp/Inspiration/MaterialDigestSection.swift`: 灵感详情提炼区。
- Modify `Sources/CalendarApp/Inspiration/InspirationViewModel.swift`: Digest 读取、操作、转换笔记结构。
- Modify `Sources/CalendarApp/Inspiration/InspirationSplitView.swift`: 提炼区与状态动作。
- Modify `Sources/CalendarApp/AppShell/AppShellView.swift`: 把生产 Coordinator 依赖传给灵感工作区，不使用全局单例。
- Modify `Sources/CalendarApp/AppEnvironment.swift`: 生产依赖装配和模型目录。
- Modify `Sources/CalendarApp/PersonalCalendarApp.swift`: Coordinator 生命周期与 Settings scene。
- Modify `Package.swift`: WhisperKit 依赖和 AVFoundation/Security linker 设置。

### Tests

- Create `Tests/CalendarAppTests/SourceKindClassifierTests.swift`.
- Create `Tests/WorkspaceDomainTests/MaterialDigestModelTests.swift`.
- Create `Tests/WorkspaceDomainTests/MaterialDigestReducerTests.swift`.
- Modify `Tests/WorkspaceDomainTests/InspirationLifecycleTests.swift`.
- Modify `Tests/CalendarPersistenceTests/WorkspaceDocumentCodecTests.swift`.
- Create `Tests/CalendarAppTests/MaterialDigestCoordinatorTests.swift`.
- Create `Tests/CalendarAppTests/MaterialSourceProviderTests.swift`.
- Create `Tests/CalendarAppTests/MaterialSourceProviderLiveTests.swift`，默认跳过、只在显式开关下访问固定公开来源。
- Create `Tests/CalendarAppTests/WhisperKitMaterialTranscriberContractTests.swift`.
- Create `Tests/CalendarAppTests/OpenAICompatibleMaterialSummarizerTests.swift`.
- Create `Tests/CalendarAppTests/DigestSettingsTests.swift`.
- Create `Tests/CalendarAppTests/MaterialDigestPresentationTests.swift`.
- Modify `Tests/CalendarAppTests/InspirationWorkspaceViewModelTests.swift`.
- Modify `Tests/CalendarAppTests/URLMetadataResolverTests.swift`.
- Modify `Tests/CalendarAppTests/AppEnvironmentWorkspaceCutoverTests.swift`.

---

### Task 1: 重新落地来源分类，不复制 CC 的脏差异

**Files:**
- Create: `Sources/CalendarApp/Inspiration/SourceKindClassifier.swift`
- Modify: `Sources/CalendarApp/Inspiration/URLMetadataResolver.swift:26-60`
- Modify: `Sources/CalendarApp/Inspiration/InspirationViewModel.swift:400-443`
- Create: `Tests/CalendarAppTests/SourceKindClassifierTests.swift`
- Modify: `Tests/CalendarAppTests/URLMetadataResolverTests.swift`
- Modify: `Tests/CalendarAppTests/InspirationWorkspaceViewModelTests.swift`

**Interfaces:**
- Produces: `enum SourceKindClassifier { static func classify(_ url: URL) -> ResolvedSourceKind? }`.
- Produces: 元数据成功和失败都保留已知 `.video` / `.audio`，未知来源继续走原有 `.article` 或 `.unknown` 语义。

- [ ] **Step 1: 写纯函数 RED 表格测试**

```swift
@Test func classifiesOnlySupportedMaterialPages() {
    let cases: [(String, ResolvedSourceKind?)] = [
        ("https://www.bilibili.com/video/BV1xx411c7mD/", .video),
        ("https://m.bilibili.com/video/av170001", .video),
        ("https://b23.tv/jKx2Ab", .video),
        ("https://www.bilibili.com/read/cv123", nil),
        ("https://space.bilibili.com/123", nil),
        ("https://www.xiaoyuzhoufm.com/episode/650a1b2ce1b3f16a04cb0f2e", .audio),
        ("https://www.xiaoyuzhoufm.com/podcast/5e2c8f0be1b3f16a04cb0f2e", nil),
        ("https://notbilibili.com/video/BV1", nil),
        ("https://fakexiaoyuzhoufm.com/episode/1", nil),
        ("https://example.com/post", nil)
    ]
    for (raw, expected) in cases {
        #expect(SourceKindClassifier.classify(URL(string: raw)!) == expected)
    }
}
```

- [ ] **Step 2: 运行 RED，确认只因类型不存在失败**

Run: `swift test --filter SourceKindClassifierTests`

Expected: compile failure `cannot find 'SourceKindClassifier' in scope`；不能出现测试语法错误。

- [ ] **Step 3: 写最小分类实现并转绿**

```swift
enum SourceKindClassifier {
    static func classify(_ url: URL) -> ResolvedSourceKind? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        if host == "b23.tv" { return .video }
        if (host == "bilibili.com" || host.hasSuffix(".bilibili.com")),
           path.hasPrefix("/video/") { return .video }
        if (host == "xiaoyuzhoufm.com" || host.hasSuffix(".xiaoyuzhoufm.com")),
           path.hasPrefix("/episode/") { return .audio }
        return nil
    }
}
```

Run: `swift test --filter SourceKindClassifierTests`

Expected: PASS.

- [ ] **Step 4: 写元数据成功/失败 RED 测试**

新增断言：B 站 HTML 成功返回 `.video`；小宇宙 HTML 成功返回 `.audio`；普通 HTML 返回 `.article`；B 站请求失败后 ViewModel 仍写 `.video` 且 `rawURL` 原样保留。

Run: `swift test --filter 'URLMetadataResolverTests|InspirationWorkspaceViewModelTests'`

Expected: B 站/小宇宙 kind 断言失败，因为生产代码仍一律 `.article` 或沿用 `.unknown`。

- [ ] **Step 5: 最小接入分类结果并跑回归**

在 `resolve` 发请求前保存 `classifiedKind`，成功返回 `classifiedKind ?? .article`；`enrichURL` catch 分支写 `SourceKindClassifier.classify(url) ?? latest.resolvedSourceKind`。不改网络超时、大小限制和 cookie 策略。

Run: `swift test --filter 'SourceKindClassifierTests|URLMetadataResolverTests|InspirationWorkspaceViewModelTests'`

Expected: PASS.

- [ ] **Step 6: 精确提交 Task 1**

```bash
git add Sources/CalendarApp/Inspiration/SourceKindClassifier.swift \
  Sources/CalendarApp/Inspiration/URLMetadataResolver.swift \
  Sources/CalendarApp/Inspiration/InspirationViewModel.swift \
  Tests/CalendarAppTests/SourceKindClassifierTests.swift \
  Tests/CalendarAppTests/URLMetadataResolverTests.swift \
  Tests/CalendarAppTests/InspirationWorkspaceViewModelTests.swift
git diff --cached --check
git commit -m "feat(inspiration): 识别可提炼的链接来源"
```

---

### Task 2: 建立 MaterialDigest 领域合同和 Validator

**Files:**
- Create: `Sources/WorkspaceDomain/MaterialDigest.swift`
- Modify: `Sources/WorkspaceDomain/WorkspaceIDs.swift`
- Modify: `Sources/WorkspaceDomain/WorkspaceState.swift`
- Modify: `Sources/WorkspaceDomain/WorkspaceValidator.swift`
- Create: `Tests/WorkspaceDomainTests/MaterialDigestModelTests.swift`
- Modify: `Sources/WorkspaceDomain/WorkspaceContentSnapshot.swift`
- Modify: `Tests/CalendarPersistenceTests/WorkspaceDocumentCodecTests.swift`
- Modify: `Tests/WorkspaceDomainTests/WorkspaceModelTests.swift`
- Modify: `Tests/WorkspaceDomainTests/WorkspaceReducerTests.swift`
- Modify: `Tests/WorkspaceDomainTests/WorkspaceSearchProjectionTests.swift`

**Interfaces:**
- Produces: `MaterialDigestID`, `MaterialDigestRunID`.
- Produces: `MaterialDigest`, `MaterialDigestRun`, `MaterialDigestStage`, `MaterialDigestResult`, `TimestampedTranscript`, `TranscriptSegment`, `InspirationSummary`, `DigestChapter`, `DigestQuote`, `DigestProvenance`, `MaterialDigestFailure`.
- Produces: `WorkspaceState.materialDigests: [InspirationID: MaterialDigest]`.

- [ ] **Step 1: 写模型与 Validator RED 测试**

```swift
@Test func validatorRejectsDanglingOrMismatchedDigest() throws {
    var state = MaterialDigestFixture.workspace()
    let inspiration = try #require(state.inspirations.values.first)
    let digest = MaterialDigestFixture.succeeded(for: inspiration)
    state.materialDigests[InspirationID()] = digest
    #expect(throws: WorkspaceValidationError.self) {
        try WorkspaceValidator.validate(state)
    }
}

@Test func validatorAcceptsThreeToSevenTakeawaysAndOrderedSegments() throws {
    let state = MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 3)
    try WorkspaceValidator.validate(state)
}
```

同时添加 RED：2 条或 8 条 takeaway、空 thesis、负时间、结束早于开始、乱序章节、成功 provenance 为空、checksum 不匹配必须被拒绝。

- [ ] **Step 2: 运行 RED**

Run: `swift test --filter MaterialDigestModelTests`

Expected: compile failure，缺少上述类型和 `materialDigests`。

- [ ] **Step 3: 定义精确领域类型**

```swift
public struct MaterialDigestRun: Codable, Equatable, Sendable {
    public let id: MaterialDigestRunID
    public var stage: MaterialDigestStage
    public let startedAt: Date
    public var updatedAt: Date
}

public enum MaterialDigestStage: String, Codable, Equatable, Sendable {
    case fetchingSource
    case awaitingModelDownloadConsent
    case downloadingModel
    case transcribing
    case summarizing
}

public struct MaterialDigest: Identifiable, Codable, Equatable, Sendable {
    public let id: MaterialDigestID
    public let inspirationID: InspirationID
    public let sourceChecksum: String
    public var currentRun: MaterialDigestRun?
    public var result: MaterialDigestResult?
    public var lastFailure: MaterialDigestFailure?
    public let createdAt: Date
    public var updatedAt: Date
}
```

`MaterialDigestFailure.Code` 只允许：`unsupportedSource`、`restrictedSource`、`sourceUnavailable`、`modelDownloadFailed`、`transcriptionFailed`、`modelNotConfigured`、`summarizationFailed`、`invalidSummary`、`cancelled`、`interrupted`。`userMessage` 必须是非空中文安全文案；不得存堆栈、密钥或完整模型响应。

- [ ] **Step 4: 把集合接进 WorkspaceState 和所有编译期 fixture**

`WorkspaceState.empty` 初始化 `materialDigests: [:]`。对所有显式构造器只补空集合，不顺手重构 fixture。

Run: `swift test --filter 'MaterialDigestModelTests|WorkspaceModelTests'`

Expected: 模型测试仍因 Validator 未实现而失败；其它 Workspace 构造器恢复编译。

- [ ] **Step 5: 实现 Validator 合同并转绿**

Validator 对每个 `(key, digest)` 检查：key 等于 `inspirationID`、灵感存在且为 URL、kind 为 video/audio、checksum 匹配、run 时间单调、result 文稿/摘要/provenance 合法。`result` 可以与新的 `currentRun` 并存以支持安全重试。

Run: `swift test --filter 'MaterialDigestModelTests|WorkspaceModelTests|InspirationLifecycleTests'`

Expected: PASS.

- [ ] **Step 6: 精确提交 Task 2**

```bash
git add Sources/WorkspaceDomain/MaterialDigest.swift \
  Sources/WorkspaceDomain/WorkspaceIDs.swift \
  Sources/WorkspaceDomain/WorkspaceState.swift \
  Sources/WorkspaceDomain/WorkspaceValidator.swift \
  Sources/WorkspaceDomain/WorkspaceContentSnapshot.swift \
  Tests/WorkspaceDomainTests/MaterialDigestModelTests.swift \
  Tests/WorkspaceDomainTests/WorkspaceModelTests.swift \
  Tests/WorkspaceDomainTests/WorkspaceReducerTests.swift \
  Tests/WorkspaceDomainTests/WorkspaceSearchProjectionTests.swift \
  Tests/CalendarPersistenceTests/WorkspaceDocumentCodecTests.swift
git diff --cached --check
git commit -m "feat(inspiration): 建立材料提炼领域合同"
```

提交前检查 staged diff：这一提交只允许 `materialDigests: [:]` 的机械 fixture 更新和本 Task 的领域/测试文件。

---

### Task 3: 实现 runID/checksum Reducer 状态机

**Files:**
- Modify: `Sources/WorkspaceDomain/WorkspaceCommand.swift`
- Create: `Sources/WorkspaceDomain/WorkspaceReducer+MaterialDigest.swift`
- Modify: `Sources/WorkspaceDomain/WorkspaceReducer.swift:67-150,242-288,299-357`
- Modify: `Sources/WorkspaceDomain/WorkspaceReducer+Inspiration.swift:133-165`
- Create: `Tests/WorkspaceDomainTests/MaterialDigestReducerTests.swift`
- Modify: `Tests/WorkspaceDomainTests/InspirationLifecycleTests.swift`

**Interfaces:**
- Consumes: Task 2 类型和 `WorkspaceChecksum.inspirationSourceChecksum`.
- Produces commands: `.startMaterialDigest`, `.advanceMaterialDigestStage`, `.completeMaterialDigest`, `.failMaterialDigest`, `.cancelMaterialDigest`, `.markInterruptedMaterialDigest`.
- Produces no-change: `.staleMaterialDigestRun`, `.staleMaterialDigestSource`, `.materialDigestNotRunning`, `.materialDigestAlreadyRunning`.

- [ ] **Step 1: 写 start/advance/complete RED 测试**

```swift
@Test func completeRequiresExactRunAndSourceAndAtomicallyReplacesResult() throws {
    let fixture = MaterialDigestReducerFixture()
    let started = try fixture.reduce(.startMaterialDigest(fixture.startPayload))
    let completed = try fixture.reduce(
        .completeMaterialDigest(fixture.completePayload),
        from: started
    )
    #expect(completed.materialDigests[fixture.inspiration.id]?.currentRun == nil)
    #expect(completed.materialDigests[fixture.inspiration.id]?.result == fixture.result)
}
```

阶段使用显式图：fetching → summarizing（已有字幕）；fetching → awaiting-consent（缺模型）；fetching → transcribing（模型已就绪且音频已下载）；awaiting-consent → downloading-model；downloading-model → fetching（模型完成后重新获取可能过期的媒体地址）；transcribing → summarizing。除此之外的跳转全部拒绝；成功只由 complete 命令产生。

- [ ] **Step 2: 运行 RED**

Run: `swift test --filter MaterialDigestReducerTests`

Expected: compile failure，缺少命令和 reducer 路由。

- [ ] **Step 3: 添加 payload 和命令路由**

```swift
public struct MaterialDigestRunExpectation: Equatable, Sendable {
    public let inspirationID: InspirationID
    public let runID: MaterialDigestRunID
    public let sourceChecksum: String
}

public struct StartMaterialDigestPayload: Equatable, Sendable {
    public let inspirationID: InspirationID
    public let digestID: MaterialDigestID
    public let runID: MaterialDigestRunID
    public let expectedSourceChecksum: String
}
```

其余 payload 组合 `MaterialDigestRunExpectation` 与 stage/completion-candidate/failure。`CompleteMaterialDigestPayload` 只接收 transcript、summary 和 provenance，不接收 `MaterialDigestResult` 或完成时间；Reducer 校验候选后使用自己的 `now` 构造最终 result。所有时间统一使用 Reducer 的 `now`，不接受调用方伪造完成时间。

- [ ] **Step 4: 实现最小状态机并转绿**

`start` 要求 active URL 灵感且 kind 为 video/audio；同一灵感已有 `currentRun` 时返回 `.noChange(.materialDigestAlreadyRunning)`。重试复用 Digest ID 和旧 result，换新 runID，清空 `lastFailure`。`complete` 只有在 runID/checksum 仍匹配且候选通过 Validator 时才原子写入 `MaterialDigestResult(completedAt: now)`。

Run: `swift test --filter MaterialDigestReducerTests`

Expected: start/advance/complete 主路径 PASS。

- [ ] **Step 5: 写竞态、取消、中断和删除 RED 测试**

覆盖：旧 run 完成、旧 checksum、取消后完成、重试后旧失败、下载确认阶段重启保留、其它活动阶段重启标记 interrupted、失败/取消保留旧 result、永久删除同时移除 Digest、归档恢复保留 Digest。

Run: `swift test --filter 'MaterialDigestReducerTests|InspirationLifecycleTests'`

Expected: 竞态和生命周期断言失败。

- [ ] **Step 6: 完成竞态和生命周期实现**

所有非 start 命令先调用一个私有 `withCurrentRun(expectation:in:)` 检查三元组；`markInterrupted` 对 `awaitingModelDownloadConsent` 返回 no-change，其余阶段清掉 run 并写 `.interrupted`。永久删除灵感在删除字典项前 `materialDigests.removeValue(forKey:)`。

Run: `swift test --filter 'MaterialDigestReducerTests|InspirationLifecycleTests|WorkspaceReducerTests|WorkspaceUndoReducerTests'`

Expected: PASS.

- [ ] **Step 7: 精确提交 Task 3**

```bash
git add Sources/WorkspaceDomain/WorkspaceCommand.swift \
  Sources/WorkspaceDomain/WorkspaceReducer.swift \
  Sources/WorkspaceDomain/WorkspaceReducer+MaterialDigest.swift \
  Sources/WorkspaceDomain/WorkspaceReducer+Inspiration.swift \
  Tests/WorkspaceDomainTests/MaterialDigestReducerTests.swift \
  Tests/WorkspaceDomainTests/InspirationLifecycleTests.swift
git diff --cached --check
git commit -m "feat(inspiration): 加入提炼运行状态机"
```

---

### Task 4: schema V5、V3/V4 显式迁移、备份恢复和确定性持久化

**Files:**
- Modify: `Sources/WorkspaceDomain/WorkspaceContentSnapshot.swift`
- Modify: `Sources/WorkspaceDomain/WorkspaceReducer.swift:299-357`
- Modify: `Sources/CalendarPersistence/WorkspaceDocument.swift:131-140`
- Modify: `Sources/CalendarPersistence/WorkspaceDocumentCodec.swift:19-115`
- Modify: `Tests/CalendarPersistenceTests/WorkspaceDocumentCodecTests.swift`
- Modify: `Tests/CalendarPersistenceTests/WorkspaceBackupServiceTests.swift`
- Modify: `Tests/WorkspaceDomainTests/WorkspaceReducerTests.swift`

**Interfaces:**
- Consumes: `WorkspaceState.materialDigests`.
- Produces: `WorkspaceDocument.currentSchemaVersion == 5`；V3/V4 解码显式补空 Digest；V3 继续迁移 Task Block 标题；V5 round-trip 保存全部 Digest。

- [ ] **Step 1: 写字节级 V4 → V5 RED 测试**

先用测试内 `LegacyWorkspaceStateV3V4` / `LegacyWorkspaceDocumentV3V4` 编码不含 `materialDigests` 字段的真实 V3 和 V4 payload；不要用 V5 类型伪装旧 schema。

```swift
let result = try WorkspaceDocumentCodec.decode(v4Bytes)
#expect(result.provenance.sourceSchema == 4)
#expect(result.state.materialDigests.isEmpty)
#expect(result.state.inspirations == legacy.inspirations)
```

同一测试文件还要构造 V3 linked-task payload，确认标题仍从 Task Block 迁移，且 Digest 为空。

Run: `swift test --filter WorkspaceDocumentCodecTests`

Expected: compile 或断言失败，因为 current schema 仍为 4，且当前 V3 decode 依赖即将新增必填字段的 `WorkspaceState`。

- [ ] **Step 2: 添加私有 V3/V4 DTO 和迁移函数**

在 `WorkspaceDocument.swift` 定义 module-internal `WorkspaceStateV3V4` 和 envelope，字段逐一复制旧 schema：revision、calendar、notes、inspirations、calendarNoteRelations、taskBlockLinks、inspirationNoteLinks。`materializedV5()` 只新增 `materialDigests: [:]`。

- [ ] **Step 3: 更新 Codec 路由和确定性排序**

`case 3` 解码 V3/V4 DTO 后先 materialize，再运行既有 `migrateV3TaskTitles`；`case 4` 只 materialize；`case 5` 解码当前 `WorkspaceDocument`。`canonicalized` 的字典键集合加入 `materialDigests`，不能把字典当普通数组保存。

Run: `swift test --filter WorkspaceDocumentCodecTests`

Expected: V1/V2/V3/V4/V5 全部 PASS，V3 标题迁移仍在。

- [ ] **Step 4: 写 V5 round-trip、快照和恢复 RED 测试**

测试一个 succeeded Digest、一个等待模型确认的 Digest、一个带旧成功结果的新重试运行；encode → decode 必须全等。`WorkspaceContentSnapshot` 备份/恢复必须包含 Digest；restore metadata 校验 key/inspirationID。

Run: `swift test --filter 'WorkspaceDocumentCodecTests|WorkspaceBackupServiceTests|WorkspaceReducerTests'`

Expected: 快照/恢复断言失败，因为 content snapshot 尚未包含 Digest。

- [ ] **Step 5: 接入快照、恢复与校验并转绿**

`WorkspaceContentSnapshot` 新增集合、构造和 materialized 参数；`reduceRestore` 的 metadata guard 加 `materialDigests.allSatisfy { key == value.inspirationID }`，最终仍走完整 Validator。

Run: `swift test --filter 'WorkspaceDocumentCodecTests|WorkspaceBackupServiceTests|WorkspaceReducerTests|WorkspaceUndoReducerTests'`

Expected: PASS.

- [ ] **Step 6: 精确提交 Task 4**

```bash
git add Sources/WorkspaceDomain/WorkspaceContentSnapshot.swift \
  Sources/WorkspaceDomain/WorkspaceReducer.swift \
  Sources/CalendarPersistence/WorkspaceDocument.swift \
  Sources/CalendarPersistence/WorkspaceDocumentCodec.swift \
  Tests/CalendarPersistenceTests/WorkspaceDocumentCodecTests.swift \
  Tests/CalendarPersistenceTests/WorkspaceBackupServiceTests.swift \
  Tests/WorkspaceDomainTests/WorkspaceReducerTests.swift
git diff --cached --check
git commit -m "feat(persistence): 迁移材料提炼到工作区 V5"
```

---

### Task 5: 用 fixture 跑通 Coordinator、取消和写入笔记

**Files:**
- Create: `Sources/CalendarApp/Inspiration/MaterialDigestProtocols.swift`
- Create: `Sources/CalendarApp/Inspiration/MaterialDigestCoordinator.swift`
- Modify: `Sources/CalendarApp/Inspiration/InspirationViewModel.swift`
- Create: `Tests/CalendarAppTests/MaterialDigestCoordinatorTests.swift`
- Modify: `Tests/CalendarAppTests/InspirationWorkspaceViewModelTests.swift`

**Interfaces:**
- Produces `MaterialSource`, `MaterialAcquisition`, `RemoteAudioAsset`, `MaterialSummarizerOutput`, `MaterialDigestCandidate`.
- Produces `MaterialAcquiring`, `MaterialAudioDownloading`, `MaterialTranscribing`, `MaterialSummarizing` protocols.
- Produces `@MainActor protocol MaterialDigestOperating` and `@MainActor final class MaterialDigestCoordinator` with `start`, `confirmModelDownload`, `cancel`, `reconcileInterruptedRuns`.

- [ ] **Step 1: 写期望端口和 Coordinator RED 测试**

```swift
protocol MaterialAcquiring: Sendable {
    func acquire(_ source: MaterialSource) async throws -> MaterialAcquisition
}

protocol MaterialAudioDownloading: Sendable {
    func download(
        _ asset: RemoteAudioAsset,
        runID: MaterialDigestRunID,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
    func cleanup(runID: MaterialDigestRunID)
}

protocol MaterialTranscribing: Sendable {
    func modelRequirement() async -> MaterialModelRequirement
    func prepareModel(progress: @escaping @Sendable (Double) -> Void) async throws
    func transcribe(_ fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws
        -> TimestampedTranscript
}

protocol MaterialSummarizing: Sendable {
    func summarize(_ transcript: TimestampedTranscript, source: MaterialSource) async throws
        -> MaterialSummarizerOutput
}
```

`MaterialSummarizerOutput` 只包含经校验的 `InspirationSummary`、实际 endpoint host、实际 model 和 `summary-contract-v1`；它不能给出完成时间。Coordinator 将它和完整 transcript 组成 `MaterialDigestCandidate`，再创建领域层 complete payload；Reducer 使用自己的 `now` 原子构造 `MaterialDigestResult`。

用 Suspended provider/downloader 验证：start 先持久化 run；字幕路径跳过 downloader 和 transcriber；音频路径在模型缺失时进入 awaiting-consent 且不下载；模型已安装时才下载到本地并识别；取消后迟到 summary 不写回。

- [ ] **Step 2: 运行 RED**

Run: `swift test --filter MaterialDigestCoordinatorTests`

Expected: compile failure，缺少端口和 Coordinator。

- [ ] **Step 3: 实现最小 Coordinator fixture 纵切**

Coordinator 持有 `[InspirationID: Task<Void, Never>]`；每个外部 await 后重新读取 Workspace 当前 run/checksum，再发下一条命令。Task cancellation 同时发 `.cancelMaterialDigest`；defer 清理任务表和调用 `audioDownloader.cleanup(runID:)`，确保 transcriber 使用完本地文件后再删目录。摘要返回后，Coordinator 用当前 run/checksum、`MaterialSummarizerOutput` 和 transcript 构造候选；只有 Reducer 可以用 `now` 盖 `completedAt` 并替换 result。

Run: `swift test --filter MaterialDigestCoordinatorTests`

Expected: 字幕 fixture 从 fetching → summarizing → result PASS；音频 fixture停在 awaiting-consent PASS。

- [ ] **Step 4: 写重启、重试和错误映射 RED 测试**

覆盖活动阶段 reconcile → interrupted、awaiting consent 保持、model未配置/受限来源/invalid summary 映射到固定中文安全文案、retry 保留旧 result。

Run: `swift test --filter MaterialDigestCoordinatorTests`

Expected: 相关断言失败。

- [ ] **Step 5: 完成恢复和错误映射并转绿**

Coordinator 只把受控 `MaterialDigestPipelineError` 映射到领域 failure；未知错误统一“提炼未完成，原始链接仍然保留。”，诊断日志不得包含响应 body、密钥或临时路径。

Run: `swift test --filter MaterialDigestCoordinatorTests`

Expected: PASS.

- [ ] **Step 6: 写笔记 Block 顺序 RED 测试**

成功 Digest 转换后的 blocks 必须依次是 link、heading2、paragraph、heading2、3～7 个 bullet，并按存在性追加章节/引用；无有效 Digest 仍只有 link；处理中/失败不写半成品；重复转换返回原 NoteID。

Run: `swift test --filter InspirationWorkspaceViewModelTests`

Expected: 摘要结构断言失败，当前只生成 link。

- [ ] **Step 7: 提取纯构造器并转绿**

在 ViewModel 文件中新增 `enum InspirationNoteDocumentBuilder`，签名：

```swift
static func document(
    for inspiration: Inspiration,
    digest: MaterialDigest?
) -> BlockDocument
```

仅当 `digest.result != nil`、`current sourceChecksum` 匹配时追加摘要；完整 transcript 不进 Note。

Run: `swift test --filter 'MaterialDigestCoordinatorTests|InspirationWorkspaceViewModelTests'`

Expected: PASS.

- [ ] **Step 8: 精确提交 Task 5**

```bash
git add Sources/CalendarApp/Inspiration/MaterialDigestProtocols.swift \
  Sources/CalendarApp/Inspiration/MaterialDigestCoordinator.swift \
  Sources/CalendarApp/Inspiration/InspirationViewModel.swift \
  Tests/CalendarAppTests/MaterialDigestCoordinatorTests.swift \
  Tests/CalendarAppTests/InspirationWorkspaceViewModelTests.swift
git diff --cached --check
git commit -m "feat(inspiration): 跑通提炼与笔记纵向链路"
```

---

### Task 6: 交付主动提炼 UI、Keychain 设置和安静状态反馈

**Files:**
- Create: `Sources/CalendarApp/Inspiration/DigestCredentialStore.swift`
- Create: `Sources/CalendarApp/Inspiration/DigestSettingsStore.swift`
- Create: `Sources/CalendarApp/Inspiration/DigestSettingsView.swift`
- Create: `Sources/CalendarApp/Inspiration/MaterialDigestSection.swift`
- Modify: `Sources/CalendarApp/Inspiration/InspirationViewModel.swift`
- Modify: `Sources/CalendarApp/Inspiration/InspirationSplitView.swift`
- Modify: `Sources/CalendarApp/AppShell/AppShellView.swift`
- Modify: `Sources/CalendarApp/AppEnvironment.swift`
- Modify: `Sources/CalendarApp/PersonalCalendarApp.swift`
- Modify: `Package.swift`
- Create: `Tests/CalendarAppTests/DigestSettingsTests.swift`
- Create: `Tests/CalendarAppTests/MaterialDigestPresentationTests.swift`

**Interfaces:**
- Produces `DigestCredentialStoring` backed by generic-password Keychain item service `ai.adeptify.jelly.digest`, account `openai-compatible-api-key`.
- Produces `DigestSettingsStore` with endpoint/model in UserDefaults keys `digest.endpoint.v1` and `digest.model.v1`.
- Produces `MaterialDigestPresentation` pure projection consumed by SwiftUI.

- [ ] **Step 1: 写 Keychain/偏好 RED 测试**

用 in-memory credential fake 验证保存、覆盖、删除和“读取失败不把空串当已配置”；endpoint 只接受 HTTPS、去掉末尾 `/`，model trim 后非空。测试不得调用用户真实 Keychain。

Run: `swift test --filter DigestSettingsTests`

Expected: compile failure。

- [ ] **Step 2: 实现 Security Keychain 和设置 Store**

Keychain 使用 `kSecClassGenericPassword`、`kSecAttrService`、`kSecAttrAccount`、`kSecValueData`；更新先 `SecItemUpdate`，不存在再 `SecItemAdd`；删除用 `SecItemDelete`。API key 绝不进 UserDefaults 或 debug description。

Run: `swift test --filter DigestSettingsTests`

Expected: PASS。

- [ ] **Step 3: 写展示状态 RED 测试**

纯投影覆盖：不支持来源不显示提炼区；未提炼显示按钮；每个 stage 显示准确中文；awaiting consent 显示“首次需要下载约 626 MB”及“下载并继续”；旧结果 + 重试显示旧结果和新进度；失败显示重试但不红色铺满详情；成功显示 thesis/takeaways/章节/引用/dropped/transcript 折叠。

Run: `swift test --filter MaterialDigestPresentationTests`

Expected: compile failure。

- [ ] **Step 4: 实现低打扰 MaterialDigestSection**

布局放在来源区之后、底部主操作之前；捕获后不弹窗。按钮和状态要有中文 accessibility label，进度变化用文本而非只靠颜色或旋转图标。取消按钮只在真实运行中显示。

Run: `swift test --filter MaterialDigestPresentationTests`

Expected: PASS。

- [ ] **Step 5: 接入 ViewModel 动作、依赖链和 Settings scene**

ViewModel 暴露 `selectedDigest`、`startSelectedDigest()`、`confirmSelectedModelDownload()`、`cancelSelectedDigest()`、`retrySelectedDigest()`；无配置时通过 `SettingsLink` 进入“材料提炼”设置。依赖必须沿 `AppEnvironment.materialDigestOperator` → `AppShellView` → `InspirationSplitView` → `InspirationViewModel` 显式传递，测试传 fake，禁止在 View 内创建 Coordinator 或访问全局单例。`PersonalCalendarApp` 增加一个 Settings scene，不新开一级导航；store load 完成后调用 operator 的 `reconcileInterruptedRuns()`。

Task 6 结束时 live environment 可以暂时是 `nil`，此时生产界面不显示可点击的假提炼按钮；Task 9 装配真实 Coordinator 后才开放生产按钮。这个中间状态只用于保证每个提交可构建，不能作为产品交付。

Run: `swift test --filter 'MaterialDigestPresentationTests|InspirationWorkspaceViewModelTests|WorkspaceSurfacePresentationTests'`

Expected: PASS。

- [ ] **Step 6: 验证没有假自动提炼路径**

新增测试：`capture()` 只调用 metadata resolver，不调用 Coordinator；启动 App、选择普通文章、归档灵感均不触发提炼；生产 environment 不装 fixture provider。

Run: `swift test --filter 'InspirationWorkspaceViewModelTests|AppEnvironmentWorkspaceCutoverTests'`

Expected: PASS。

- [ ] **Step 7: 精确提交 Task 6**

```bash
git add Package.swift \
  Sources/CalendarApp/Inspiration/DigestCredentialStore.swift \
  Sources/CalendarApp/Inspiration/DigestSettingsStore.swift \
  Sources/CalendarApp/Inspiration/DigestSettingsView.swift \
  Sources/CalendarApp/Inspiration/MaterialDigestSection.swift \
  Sources/CalendarApp/Inspiration/InspirationViewModel.swift \
  Sources/CalendarApp/Inspiration/InspirationSplitView.swift \
  Sources/CalendarApp/AppShell/AppShellView.swift \
  Sources/CalendarApp/AppEnvironment.swift \
  Sources/CalendarApp/PersonalCalendarApp.swift \
  Tests/CalendarAppTests/DigestSettingsTests.swift \
  Tests/CalendarAppTests/MaterialDigestPresentationTests.swift \
  Tests/CalendarAppTests/InspirationWorkspaceViewModelTests.swift \
  Tests/CalendarAppTests/WorkspaceSurfacePresentationTests.swift \
  Tests/CalendarAppTests/AppEnvironmentWorkspaceCutoverTests.swift
git diff --cached --check
git commit -m "feat(inspiration): 加入主动提炼与安全设置"
```

---

### Task 7: 真实获取 B 站字幕与小宇宙音频

**Files:**
- Create: `Sources/CalendarApp/Inspiration/MaterialSourceProviders.swift`
- Modify: `Sources/CalendarApp/Inspiration/MaterialDigestProtocols.swift`
- Create: `Tests/CalendarAppTests/MaterialSourceProviderTests.swift`
- Create: `Tests/CalendarAppTests/MaterialSourceProviderLiveTests.swift`

**Interfaces:**
- Produces `BilibiliMaterialAcquirer`, `XiaoyuzhouMaterialAcquirer`, `RoutedMaterialAcquirer`, `TemporaryMaterialAudioDownloader`.
- Produces `MaterialAcquisition.transcript(TimestampedTranscript)` or `.remoteAudio(RemoteAudioAsset)`.
- Produces `RemoteAudioAsset(url: URL, requestHeaders: [String: String], estimatedBytes: Int64?)`.

- [ ] **Step 1: 写完全离线 URLProtocol fixture RED 测试**

B 站 fixture 覆盖：b23 302 到 video 页、`__INITIAL_STATE__` 提取 bvid/cid、player v2 中文人工字幕优先于 ai-zh、字幕段映射时间戳、无合格字幕时解析 DASH audio、403 映射 restricted。小宇宙 fixture 覆盖 `og:audio`、JSON-LD `contentUrl`、`__NEXT_DATA__` enclosure、节目首页拒绝、无音频失败。

Run: `swift test --filter MaterialSourceProviderTests`

Expected: compile failure。

- [ ] **Step 2: 实现共同安全网络层**

`MaterialHTTPClient` 使用 ephemeral URLSession、请求/资源超时 20/120 秒、cookie 永不接受、最多 5 次重定向、HTML 最大 2 MB、字幕最大 10 MB、音频流最大 1.5 GB。所有重定向最终 URL 重新校验 HTTPS；页面请求只允许支持来源域，媒体 CDN URL 必须来自已解析的受信页面/API 响应。页面请求设置稳定桌面 User-Agent、`Accept-Language: zh-CN,zh;q=0.9`；B 站媒体请求带最终视频页 Referer。

- [ ] **Step 3: 实现 B 站字幕优先**

解析最终页面的 `window.__INITIAL_STATE__` 得到当前落地分 P 的 bvid/cid/title/duration；调用 `/x/player/v2?bvid=...&cid=...`，按 `zh-Hans`、`zh-CN`、`zh`、`ai-zh` 排序字幕。字幕至少 30 个非空段且总有效汉字/字母不少于 200 才合格，否则返回 DASH audio；audio 请求保留 `Referer` 和浏览器 User-Agent。

Run: `swift test --filter MaterialSourceProviderTests`

Expected: B 站 fixture PASS。

- [ ] **Step 4: 实现小宇宙单集音频**

依次读 `meta[property='og:audio']`、JSON-LD `AudioObject.contentUrl`、`__NEXT_DATA__` 内 `enclosure.url` / `audioUrl`。只接受 `/episode/` 页面和 HTTPS 音频；节目首页返回 `.unsupportedSource`。

Run: `swift test --filter MaterialSourceProviderTests`

Expected: 全部 PASS。

- [ ] **Step 5: 实现任务级临时目录与流式下载**

`TemporaryMaterialAudioDownloader` 使用 `FileManager.default.temporaryDirectory/Jelly-MaterialDigest/<runID UUID>`；文件名固定 `source-audio` 加由 MIME 判定的扩展名，`audio/mp4` 固定保存为 `.m4a` 供 AVFoundation/WhisperKit 识别。下载到 `.partial`，完成后原子 rename；Coordinator 在识别成功、失败或取消后的 defer 中调用 `cleanup(runID:)` 删除整个 run 目录。清理失败只记不含绝对路径的诊断，不改变业务结果。

Run: `swift test --filter MaterialSourceProviderTests`

Expected: 取消后 partial 和目录都不存在，超限下载失败，PASS。

- [ ] **Step 6: 添加默认禁用的固定公开来源探测**

`MaterialSourceProviderLiveTests` 只有在 `JELLY_RUN_LIVE_MATERIAL_PROBE=1` 时启用；输入固定为 `https://www.bilibili.com/video/BV1xx411c7mD/` 和 `https://www.xiaoyuzhoufm.com/episode/69b6c67ef8b8079bfa7b7260`。测试只记录最终 source kind、acquisition 分支、字幕段数或 estimated bytes，不打印响应正文、CDN URL、header 或临时路径。普通 `swift test` 必须保持纯离线。

Run: `JELLY_RUN_LIVE_MATERIAL_PROBE=1 swift test --filter MaterialSourceProviderLiveTests`

Expected: 两个测试实际运行而不是 skip；B 站得到 transcript 或 remoteAudio，小宇宙得到 remoteAudio。

- [ ] **Step 7: 精确提交 Task 7**

```bash
git add Sources/CalendarApp/Inspiration/MaterialSourceProviders.swift \
  Sources/CalendarApp/Inspiration/MaterialDigestProtocols.swift \
  Tests/CalendarAppTests/MaterialSourceProviderTests.swift \
  Tests/CalendarAppTests/MaterialSourceProviderLiveTests.swift
git diff --cached --check
git commit -m "feat(inspiration): 获取真实字幕与音频来源"
```

---

### Task 8: 接入 WhisperKit 本机识别和首次模型下载体验

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CalendarApp/Inspiration/WhisperKitMaterialTranscriber.swift`
- Modify: `Sources/CalendarApp/Inspiration/MaterialDigestCoordinator.swift`
- Modify: `Sources/CalendarApp/AppEnvironment.swift`
- Modify: `Sources/CalendarApp/PersonalCalendarApp.swift`
- Create: `Tests/CalendarAppTests/WhisperKitMaterialTranscriberContractTests.swift`
- Modify: `Tests/CalendarAppTests/AppEnvironmentWorkspaceCutoverTests.swift`

**Interfaces:**
- Consumes: Task 5 `MaterialTranscribing`.
- Produces: actor-isolated `WhisperKitMaterialTranscriber` with model directory `<AppData>/Models/WhisperKit` and fixed variant `large-v3-v20240930_626MB`.

- [ ] **Step 1: 先添加依赖锁定和编译 RED 合同测试**

```swift
.package(
    url: "https://github.com/argmaxinc/argmax-oss-swift.git",
    exact: "1.0.0"
)
```

CalendarApp target 只依赖 `.product(name: "WhisperKit", package: "argmax-oss-swift")`，不引入 `ArgmaxOSS` umbrella、SpeakerKit 或 TTSKit。

测试用 fake backend 验证 `modelRequirement()` 在目录缺失时报告 `downloadRequired(approximateBytes: 626_000_000)`，存在有效模型目录时报告 ready。

Run: `swift test --filter WhisperKitMaterialTranscriberContractTests`

Expected: compile failure，缺少 transcriber wrapper。

- [ ] **Step 2: 实现模型准备 wrapper**

wrapper 是 actor，`WhisperKit` 实例只在 actor 内创建和使用。下载调用官方 `WhisperKit.download(variant:downloadBase:from:progressCallback:)`，`downloadBase` 精确传 App 数据目录的 `Models/WhisperKit`；完成后以 `WhisperKitConfig(modelFolder: downloadedFolder.path, download: false, prewarm: loadPolicy.prewarm, load: true)` 初始化。`loadPolicy` 的最终合同见 Task 11：高内存 Mac 优先首次响应，低内存 Mac 保留顺序预热；进度 callback 映射 0...1，取消后不发布 ready。

Run: `swift test --filter WhisperKitMaterialTranscriberContractTests`

Expected: 模型状态测试 PASS；测试不下载真实 626 MB 模型。

- [ ] **Step 3: 写时间戳映射和取消 RED 测试**

fake Whisper backend 返回多个 `TranscriptionSegment`；wrapper 转成 start/end/text，去掉空白段并保持单调。Task cancellation 必须停止后续 result 发布并释放 engine；不删除已经完整安装的共享模型。

Run: `swift test --filter WhisperKitMaterialTranscriberContractTests`

Expected: 时间戳/取消断言失败。

- [ ] **Step 4: 实现真实 transcribe 调用并转绿**

调用 `transcribe(audioPath:decodeOptions:callback:)`，语言不强制中文，保留原语言；callback 只更新进度，不把部分文稿写入 Workspace。最终合并返回的 segments 并交领域 Validator。

Run: `swift test --filter WhisperKitMaterialTranscriberContractTests`

Expected: PASS。

- [ ] **Step 5: 接通等待确认 → 下载 → 识别状态**

Coordinator 收到 remote audio 且模型缺失时发 stage `awaitingModelDownloadConsent`，不持久化可能过期的 CDN URL；用户确认后进入 `downloadingModel` 并先准备模型，完成后回到 `fetchingSource` 重新解析来源、下载当前音频，再进入 `transcribing`。App 重启后等待确认仍可继续，其它阶段按 interrupted 处理。

Run: `swift test --filter 'MaterialDigestCoordinatorTests|WhisperKitMaterialTranscriberContractTests|AppEnvironmentWorkspaceCutoverTests'`

Expected: PASS。

- [ ] **Step 6: 验证 release 构建不嵌模型、不依赖外部 CLI**

Run: `swift build -c release --product PersonalCalendar`

Expected: exit 0；`find .build -path '*large-v3*' -type f` 不得显示模型被复制进 app product；源码 `rg -n 'Process\(|yt-dlp|whisperkit-cli|python' Sources` 无生产命中。

- [ ] **Step 7: 精确提交 Task 8**

```bash
git add Package.swift Package.resolved \
  Sources/CalendarApp/Inspiration/WhisperKitMaterialTranscriber.swift \
  Sources/CalendarApp/Inspiration/MaterialDigestCoordinator.swift \
  Sources/CalendarApp/AppEnvironment.swift Sources/CalendarApp/PersonalCalendarApp.swift \
  Tests/CalendarAppTests/WhisperKitMaterialTranscriberContractTests.swift \
  Tests/CalendarAppTests/AppEnvironmentWorkspaceCutoverTests.swift
git diff --cached --check
git commit -m "feat(inspiration): 接入本机 WhisperKit 识别"
```

---

### Task 9: 接入 OpenAI 兼容结构化摘要

**Files:**
- Create: `Sources/CalendarApp/Inspiration/OpenAICompatibleMaterialSummarizer.swift`
- Modify: `Sources/CalendarApp/Inspiration/MaterialDigestCoordinator.swift`
- Modify: `Sources/CalendarApp/AppEnvironment.swift`
- Modify: `Sources/CalendarApp/PersonalCalendarApp.swift`
- Create: `Tests/CalendarAppTests/OpenAICompatibleMaterialSummarizerTests.swift`
- Modify: `Tests/CalendarAppTests/MaterialDigestCoordinatorTests.swift`

**Interfaces:**
- Consumes: `DigestSettingsStore` 和 `DigestCredentialStoring`.
- Produces: `OpenAICompatibleMaterialSummarizer: MaterialSummarizing`，返回 `MaterialSummarizerOutput`，不返回最终领域结果。
- Produces request: POST `<endpoint>/chat/completions` with model、messages、`response_format.type=json_schema`、strict schema。

- [ ] **Step 1: 写请求合同 RED 测试**

URLProtocol 捕获 body，断言：endpoint 无双斜杠、Authorization 只在 header、model 精确、temperature 0.2、response schema strict、系统提示区分 video/audio、小宇宙提示要求广告写入 dropped 且不从 transcript 删除。

Run: `swift test --filter OpenAICompatibleMaterialSummarizerTests`

Expected: compile failure。

- [ ] **Step 2: 定义固定 JSON Schema 和提示**

Schema required 字段：`thesis` string、`takeaways` array 3...7、`chapters` array of `{startSeconds,title,points}`、`quotes` array of `{speaker,startSeconds,text}`、`dropped` string array。`additionalProperties` 全部 false。输入把 timestamp segments 编为 `[mm:ss-mm:ss] text`，不发送文件路径或来源凭据。

- [ ] **Step 3: 实现请求和严格响应解码**

只接受 2xx；401/403 → modelNotConfigured 安全文案，413/context-length → summarizationFailed“材料超过当前模型可处理长度”，429/5xx → 可重试失败。解析 `choices[0].message.content` 后用 `JSONDecoder` 解码候选，再由共享 summary validator 检查。

Run: `swift test --filter OpenAICompatibleMaterialSummarizerTests`

Expected: 请求、成功响应和错误映射 PASS。

- [ ] **Step 4: 写不合法输出和 secret 日志 RED 测试**

覆盖 markdown code fence、缺 thesis、2/8 takeaways、乱序章节、非 JSON、refusal、空 choices、响应 body 含 key。任何错误 description、failure userMessage、diagnostic event 都不能包含测试 key 或完整 body。

Run: `swift test --filter OpenAICompatibleMaterialSummarizerTests`

Expected: 安全断言失败直到 sanitizer 完成。

- [ ] **Step 5: 完成 sanitizer 和 Coordinator 生产装配**

生产 AppEnvironment 使用真实 source acquirer、audio downloader、Whisper transcriber、OpenAI summarizer 创建唯一 Coordinator，并赋给 Task 6 预留的 `materialDigestOperator`；测试 environment 继续显式注入 fake。摘要成功后 Coordinator 从 `MaterialSummarizerOutput` 构造 provenance：endpoint host、model、`sourceChecksum`、`summary-contract-v1`，不存 key；生成时间和 `completedAt` 统一由 Reducer 的 `now` 写入。`PersonalCalendarApp` 必须在 store load 后执行一次重启恢复，再允许用户操作。

Run: `swift test --filter 'OpenAICompatibleMaterialSummarizerTests|MaterialDigestCoordinatorTests|AppEnvironmentWorkspaceCutoverTests'`

Expected: PASS。

- [ ] **Step 6: 精确提交 Task 9**

```bash
git add Sources/CalendarApp/Inspiration/OpenAICompatibleMaterialSummarizer.swift \
  Sources/CalendarApp/Inspiration/MaterialDigestCoordinator.swift \
  Sources/CalendarApp/AppEnvironment.swift \
  Sources/CalendarApp/PersonalCalendarApp.swift \
  Tests/CalendarAppTests/OpenAICompatibleMaterialSummarizerTests.swift \
  Tests/CalendarAppTests/MaterialDigestCoordinatorTests.swift \
  Tests/CalendarAppTests/AppEnvironmentWorkspaceCutoverTests.swift
git diff --cached --check
git commit -m "feat(inspiration): 生成可校验的材料摘要"
```

---

### Task 10: 工程门禁、打包产物和 Grok 候选交接

**Files:**
- Modify only when a failing gate has a focused RED reproduction: files already listed in Tasks 1-9
- Do not create a completion/signoff document on behalf of the user

**Interfaces:**
- Produces: clean candidate branch, exact commits, full test/build evidence, real-source probe evidence, remaining `UNVERIFIED` user items.

- [ ] **Step 1: 先跑 focused 汇总门禁**

```bash
swift test --filter 'SourceKindClassifierTests|MaterialDigestModelTests|MaterialDigestReducerTests|WorkspaceDocumentCodecTests|MaterialDigestCoordinatorTests|MaterialSourceProviderTests|WhisperKitMaterialTranscriberContractTests|OpenAICompatibleMaterialSummarizerTests|DigestSettingsTests|MaterialDigestPresentationTests|InspirationWorkspaceViewModelTests'
```

Expected: exit 0，不能出现“0 tests matched”。若失败，先写/确认最小 RED 再修，禁止直接改测试期待来迎合实现。

- [ ] **Step 2: 跑完整工程验证**

```bash
swift test
swift build -c release --product PersonalCalendar
Scripts/build-app.sh
git diff --check
```

Expected: 全部 exit 0；记录完整输出摘要、测试失败数 0、最终 `.app` 绝对路径和 SHA-256。

- [ ] **Step 3: 做安全和假能力扫描**

```bash
rg -n 'api[_-]?key|Authorization|Bearer |cookies?\.txt|yt-dlp|whisperkit-cli|Process\(' Sources Tests
find . -type f \( -name '*.mp3' -o -name '*.m4a' -o -name '*.wav' -o -name '*.m4s' \) -not -path './.build/*'
git status --short --branch
```

Expected: 生产源码没有硬编码密钥、cookie、外部 CLI；仓库没有下载的真实音频；工作区只包含计划内候选提交且 status clean。

- [ ] **Step 4: 用公开来源做非凭据真实探测**

Run: `JELLY_RUN_LIVE_MATERIAL_PROBE=1 swift test --filter MaterialSourceProviderLiveTests`

对固定公开输入 `https://www.bilibili.com/video/BV1xx411c7mD/` 和 `https://www.xiaoyuzhoufm.com/episode/69b6c67ef8b8079bfa7b7260` 运行真实 acquisition probe：确认最终来源类型、字幕或音频分支、取消和临时文件清理。不得使用用户 Cookie 或模型 API key。若固定输入下线，再选一个当前可匿名访问的同类 URL，并在决策包记录替代 URL、选择时间和 HTTP 状态；不提交响应正文或临时路径。输出必须证明两个 live tests 实际运行，不能把默认 skip 算 PASS。

Expected: 至少一个 B 站字幕/音频 acquisition 和一个小宇宙 audio acquisition 成功；否则候选状态必须明确为 blocked，不得声称产品实操通过。

- [ ] **Step 5: 启动最终打包 App 做无凭据旅程实操**

使用隔离数据目录启动最终 `.app`；隔离目录必须同时派生独立 Keychain 服务和 endpoint/model 偏好域，不读取或覆盖正式 Jelly 配置。捕获普通文章（无提炼区）、捕获 B 站/小宇宙（出现主动提炼）、未配置模型点击后进入设置、取消返回、原始链接仍可复制、退出重启后状态诚实。另用合法 succeeded Digest fixture 实操“写入笔记”：若遇到 `commitPending`，必须立即显示“继续确认写入”，后续只能用原事务令牌继续确认，直到明确提交后才出现成功提示并移动到“已成笔记”；打开笔记后检查原链接和摘要结构，再退出重开同一隔离数据，确认笔记与回执仍可读取。观察点击到可见反馈，不把自动化工具等待算作 App 响应；fixture 只进入隔离验收数据，不得进入发布默认路径。

Expected: 逐项记录 PASS/FAIL/UNVERIFIED；仅无凭据旅程可在本阶段判定产品实操。

- [ ] **Step 6: 生成 Grok → Codex 决策包，不冒充完成**

Grok 最终消息必须包含：候选分支/HEAD、Task 1-10 提交、实际 diff 范围、每条验证命令 exit、真实来源 probe 结果、最终 `.app` 和 SHA-256、尚未用真实用户摘要凭据走通的项目、任何 `UNVERIFIED` 主观项。不得写“用户验收通过”“9 分已达成”。

- [ ] **Step 7: 停止写入，等待 Codex 独立 review**

不要 merge、push、tag、release、安装覆盖用户现有 Jelly、修改原始 dirty `main`，也不要清理候选 worktree。Codex 将独立检查 diff、重跑门禁、修复 review findings，并用最终包继续真实旅程。

---

### Task 11: 缩短 large-v3 首次识别等待，不降低转写模型

> **2026-08-22 性能补充：** 最终候选在 M5 Pro、48 GiB 内存上，对约 11.08 秒真实小宇宙音频，从进入识别到友好终态实测约 285.3 秒。统一日志显示 MiniMax 摘要约 1 秒，主要时间落在 WhisperKit/Core ML 首次加载、设备特化和识别。当前 `LiveWhisperKitEngine` 已按进程缓存 `WhisperKit`，但无条件使用 `prewarm: true`。WhisperKit 1.0.0 源码说明该选项以较低峰值内存换取一次 load-unload-load，命中 Core ML 特化缓存时加载时间约乘 2；因此不能把“再加一层缓存”当成修复。

**Files:**
- Modify: `Sources/CalendarApp/Inspiration/WhisperKitMaterialTranscriber.swift`
- Modify: `Tests/CalendarAppTests/WhisperKitMaterialTranscriberContractTests.swift`
- Do not modify: 模型 variant、下载确认、解码参数、摘要模型、来源获取或 Workspace schema

**Interfaces:**
- Produces: `struct WhisperKitLoadPolicy: Equatable, Sendable`。
- Produces: `static let fastLoadMinimumPhysicalMemoryBytes: UInt64 = 32 * 1_024 * 1_024 * 1_024`。
- Produces: `static func automatic(physicalMemoryBytes: UInt64) -> WhisperKitLoadPolicy`；物理内存不少于 32 GiB 时 `prewarm == false`，低于 32 GiB 时 `prewarm == true`。
- Consumes: `LiveWhisperKitEngine(loadPolicy:)`；生产默认值只从 `ProcessInfo.processInfo.physicalMemory` 计算一次。
- Preserves: `cachedKit` 与 `cachedModelFolder` 的进程内复用；同一模型目录的第二次识别不得重新构造 `WhisperKit`。

32 GiB 是 Jelly 的产品工程阈值，不是 WhisperKit 官方推荐值：它让本次 48 GiB 目标设备走低等待路线，同时不拿 8/16/24 GiB 设备的峰值内存冒险。真实基准若证明该阈值仍造成系统内存压力，必须另开有证据的调整，不得在本 Task 猜测扩大适用范围。

- [ ] **Step 1: 写加载策略 RED 测试**

在 `WhisperKitMaterialTranscriberContractTests` 增加纯函数边界表：

```swift
@Test func loadPolicyUsesFastPathOnlyAtOrAboveThirtyTwoGiB() {
    let gib: UInt64 = 1_024 * 1_024 * 1_024
    #expect(WhisperKitLoadPolicy.automatic(physicalMemoryBytes: 16 * gib).prewarm)
    #expect(WhisperKitLoadPolicy.automatic(physicalMemoryBytes: 31 * gib).prewarm)
    #expect(!WhisperKitLoadPolicy.automatic(physicalMemoryBytes: 32 * gib).prewarm)
    #expect(!WhisperKitLoadPolicy.automatic(physicalMemoryBytes: 48 * gib).prewarm)
}
```

Run: `swift test --filter WhisperKitMaterialTranscriberContractTests.loadPolicyUsesFastPathOnlyAtOrAboveThirtyTwoGiB`

Expected: compile failure `cannot find 'WhisperKitLoadPolicy' in scope`；不能先改生产代码。

- [ ] **Step 2: 实现最小纯策略并转绿**

在 transcriber 文件中加入：

```swift
struct WhisperKitLoadPolicy: Equatable, Sendable {
    static let fastLoadMinimumPhysicalMemoryBytes: UInt64 = 32 * 1_024 * 1_024 * 1_024

    let prewarm: Bool

    static func automatic(physicalMemoryBytes: UInt64) -> Self {
        Self(prewarm: physicalMemoryBytes < fastLoadMinimumPhysicalMemoryBytes)
    }

    static func automatic(processInfo: ProcessInfo = ProcessInfo.processInfo) -> Self {
        automatic(physicalMemoryBytes: processInfo.physicalMemory)
    }
}
```

Run: `swift test --filter WhisperKitMaterialTranscriberContractTests.loadPolicyUsesFastPathOnlyAtOrAboveThirtyTwoGiB`

Expected: PASS。

- [ ] **Step 3: 写生产配置 RED 合同并让策略可观察**

测试直接读取尚不存在的纯配置工厂，不加载模型：

```swift
@Test func liveEngineConfigurationUsesInjectedLoadPolicy() {
    let gib: UInt64 = 1_024 * 1_024 * 1_024
    let folder = URL(fileURLWithPath: "/tmp/jelly-whisper-model", isDirectory: true)
    let fast = LiveWhisperKitEngine.makeConfiguration(
        modelFolder: folder,
        loadPolicy: .automatic(physicalMemoryBytes: 48 * gib)
    )
    let conservative = LiveWhisperKitEngine.makeConfiguration(
        modelFolder: folder,
        loadPolicy: .automatic(physicalMemoryBytes: 16 * gib)
    )
    #expect(fast.modelFolder == folder.path)
    #expect(fast.prewarm == false)
    #expect(fast.load == true)
    #expect(fast.download == false)
    #expect(conservative.prewarm == true)
}
```

该测试同时锁定模型目录、`load` 和 `download`，避免为了改 `prewarm` 意外恢复运行时下载。

Run: `swift test --filter WhisperKitMaterialTranscriberContractTests.liveEngineConfigurationUsesInjectedLoadPolicy`

Expected: compile failure，缺少 `makeConfiguration(modelFolder:loadPolicy:)`。

- [ ] **Step 4: 把策略接到唯一 WhisperKit 初始化点**

生产实现精确保持缓存合同，只改配置来源：

```swift
actor LiveWhisperKitEngine: WhisperKitEngine {
    private let loadPolicy: WhisperKitLoadPolicy
    private var cachedKit: WhisperKit?
    private var cachedModelFolder: URL?

    init(loadPolicy: WhisperKitLoadPolicy = .automatic()) {
        self.loadPolicy = loadPolicy
    }

    nonisolated static func makeConfiguration(
        modelFolder: URL,
        loadPolicy: WhisperKitLoadPolicy
    ) -> WhisperKitConfig {
        WhisperKitConfig(
            modelFolder: modelFolder.path,
            prewarm: loadPolicy.prewarm,
            load: true,
            download: false
        )
    }
}
```

在现有缓存 miss 分支里，把内联 `WhisperKitConfig(...)` 精确替换为 `Self.makeConfiguration(modelFolder: modelFolder, loadPolicy: loadPolicy)`；下载方法、缓存 hit 分支和识别调用逐行保持不变。禁止改为 `prewarm: false` 常量；禁止删除 `cachedKit`；禁止换成 tiny/base/small/turbo 或把音频上传到新服务。

Run: `swift test --filter WhisperKitMaterialTranscriberContractTests`

Expected: 全套合同 PASS，测试不访问网络、不下载模型。

- [ ] **Step 5: 跑相关回归并提交 Grok 候选**

```bash
swift test --filter 'WhisperKitMaterialTranscriberContractTests|MaterialDigestCoordinatorTests|MaterialDigestPresentationTests'
git diff --check
git add Sources/CalendarApp/Inspiration/WhisperKitMaterialTranscriber.swift \
  Tests/CalendarAppTests/WhisperKitMaterialTranscriberContractTests.swift
git diff --cached --check
git commit -m "perf(inspiration): 缩短高内存设备识别预热"
```

Expected: exit 0；提交只包含上述两个实现/测试文件，计划文档仍由 Codex 单独持有或另作计划提交，不混入 Grok 实现提交。

- [ ] **Step 6: Codex 独立性能验收，不接受只测纯函数**

Codex 用最终打包 `.app`、隔离 Workspace/偏好/Keychain/模型目录和同一约 11.08 秒公开小宇宙样本重复实操。不得删除系统 Core ML 缓存来制造结果，也不得把 Computer Use 工具等待算进 App 响应。分别记录：

1. 新进程从 UI 进入 `.transcribing` 到离开 `.transcribing` 的秒数；
2. 同一 App 进程、同一已安装模型的第二次识别秒数；
3. 点击“取消”到 UI 离开运行态的可见反馈时间；
4. 运行前后 App 峰值 RSS、系统是否出现内存压力、App 是否崩溃或失去响应；
5. 最终结果/友好失败、临时音频清理和重启状态是否仍符合原合同。

性能进入用户验收的硬门：

- 模型仍精确为 `large-v3-v20240930_626MB`，解码参数与摘要模型不变；
- 48 GiB 设备实际选择 `prewarm == false`；
- 新进程识别阶段不超过 120 秒，并且相对 285.3 秒基线至少缩短 40%；
- 同进程热识别阶段不超过 30 秒；
- 点击取消在 300 ms 内出现可见状态变化，取消后不发布文稿、摘要或笔记写入；
- 峰值 RSS 不超过 8 GiB，系统无黄色/红色内存压力，最终 App 无崩溃或持续卡死；
- 原链接、旧成功结果、重试、临时文件清理和重启恢复没有回归。

任一硬门失败只能报告该性能方案未达到产品实操门禁。若新进程识别仍超过 120 秒，停止继续微调这个布尔值，保留 large-v3 质量证据并向用户提交下一步选择：评测更快的本地模型、增加可选云端转写，或接受首次等待；未经用户选择不得偷偷切换。

## Task 12：让 MiniMax-M3 的真实摘要延迟落在可靠窗口内

**结论与边界：** 当前生产摘要器把 `timeoutIntervalForRequest` 固定为 20 秒。真实 MiniMax-M3 结构化请求曾在约 21 秒时被映射为 `summarizationFailed`；同一密钥、endpoint、model、schema 和输入在诊断性 90 秒窗口下于 13.4 秒成功并通过 `summary-contract-v2`。这证明 MiniMax 链路可用，也证明 20 秒门槛对正常延迟抖动过于脆弱。Task 12 只扩大单次请求窗口到 60 秒，不改 endpoint、模型、schema、响应大小上限、错误映射、资源总上限或取消语义，不增加自动重试，避免重复计费和重复请求。

**Files:**

- Modify: `Sources/CalendarApp/Inspiration/OpenAICompatibleMaterialSummarizer.swift`
- Modify: `Tests/CalendarAppTests/OpenAICompatibleMaterialSummarizerTests.swift`

### Step 1：写配置工厂 RED 合同

新增一个测试，直接读取尚不存在的纯配置工厂；测试不得访问网络：

```swift
@Test func productionTransportAllowsModelLatencyJitterWithoutUnboundedWait() {
    let base = URLSessionConfiguration.ephemeral
    base.timeoutIntervalForRequest = 3
    base.timeoutIntervalForResource = 4

    let configured = OpenAICompatibleMaterialSummarizer.makeSessionConfiguration(from: base)

    #expect(configured !== base)
    #expect(configured.timeoutIntervalForRequest == 60)
    #expect(configured.timeoutIntervalForResource == 120)
    #expect(configured.httpCookieAcceptPolicy == .never)
    #expect(configured.httpShouldSetCookies == false)
}
```

Run: `swift test --filter OpenAICompatibleMaterialSummarizerTests.productionTransportAllowsModelLatencyJitterWithoutUnboundedWait`

Expected: compile failure，缺少 `makeSessionConfiguration(from:)`。

### Step 2：最小实现并接回唯一 URLSession 初始化点

在 `OpenAICompatibleMaterialSummarizer` 内增加可由 `@testable` 读取的纯工厂，并让初始化器只使用该工厂：

```swift
nonisolated static func makeSessionConfiguration(
    from configuration: URLSessionConfiguration
) -> URLSessionConfiguration {
    let config = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 120
    config.httpCookieAcceptPolicy = .never
    config.httpShouldSetCookies = false
    return config
}
```

禁止改成无限等待；禁止把 resource timeout 提高到 120 秒以上；禁止增加 retry；禁止改变 `session.bytes(for:)` 的逐字节上限与 `Task.checkCancellation()`；禁止打印请求、响应或密钥。

Run: `swift test --filter OpenAICompatibleMaterialSummarizerTests`

Expected: 全套摘要器合同 PASS。

### Step 3：相关回归与 Grok 候选提交

```bash
swift test --filter 'OpenAICompatibleMaterialSummarizerTests|MaterialDigestCoordinatorTests|DigestSettingsTests|MaterialDigestPresentationTests'
git diff --check
git add Sources/CalendarApp/Inspiration/OpenAICompatibleMaterialSummarizer.swift \
  Tests/CalendarAppTests/OpenAICompatibleMaterialSummarizerTests.swift
git diff --cached --check
git commit -m "fix(inspiration): 放宽真实摘要等待窗口"
```

Expected: exit 0；提交只包含两个指定文件。

### Step 4：Codex 独立复核与真实 MiniMax 门禁

Codex 逐行检查候选 diff，重跑摘要器与完整回归，并通过 `appkey exec minimax -- sh -c '...'` 注入密钥，至少连续执行三次同一生产摘要器、MiniMax-M3、`https://api.minimaxi.com/v1`、真实结构化 schema 的探针。密钥、Authorization、请求/响应原文不得出现在日志；临时探针不得提交。

进入最终打包的硬门：

- 三次请求都不再因 20 秒边界失败；每次在 60 秒内结束；
- 成功结果都通过 `summary-contract-v2` 本地解码和校验；
- 401/403/413/400 schema/429/5xx、4 MB 响应上限、短材料友好失败与取消语义不回归；
- `swift test`、release build、最终 `.app` 打包和严格签名验证通过；
- 只据此报告工程验证和真实模型集成验证，最终 App 的完整点击旅程与主观等待体验仍需产品实操和用户本人验收。

## Task 13：让短而重复的测试材料稳定得到友好失败

**结论与边界：** 同一个约 11 秒小宇宙测试片段，WhisperKit 可能给出“测试”重复若干次并带 `Thank you`，总 semantic mass 为 12。MiniMax-M3 对这种没有可提炼观点的输入可能合法地给出无法通过摘要合同的结果；现有 `isShortAndSparse` 只看总 mass `<= 3`，因此会把它暴露成“摘要无法校验”，而不是“没有识别到可提炼的内容”。Task 13 只在**模型结果已是 invalidSummary**、材料不超过 30 秒且语义单元高度重复时，把失败映射为 `insufficientContent`；有效摘要仍照常成功，超过 30 秒的材料仍保持严格 `invalidSummary`，绝不放松 schema、证据、时间戳或内容长度校验。

**Files:**

- Modify: `Sources/CalendarApp/Inspiration/MaterialDigestProtocols.swift`
- Modify: `Tests/CalendarAppTests/OpenAICompatibleMaterialSummarizerTests.swift`

### Step 1：写重复材料 RED 合同

在 `shortSparseClassificationUsesDurationAndMassNotPhrases` 附近增加精确样本：

```swift
let repetitiveTestTranscript = TimestampedTranscript(segments: [
    TranscriptSegment(startSeconds: 0, endSeconds: 7.4, text: "测试 测试 测试 测试"),
    TranscriptSegment(startSeconds: 7.4, endSeconds: 9.5, text: "测试"),
    TranscriptSegment(startSeconds: 9.5, endSeconds: 11.04, text: "Thank you.")
])
#expect(MaterialTranscriptSemantics.semanticMass(repetitiveTestTranscript) == 12)
#expect(MaterialTranscriptSemantics.semanticDiversityMass(repetitiveTestTranscript) == 4)
#expect(MaterialTranscriptSemantics.isShortAndSparse(repetitiveTestTranscript))
```

再让 mock 模型对该 transcript 返回空 thesis/takeaways，断言最终错误为 `.insufficientContent`；同时保留已有“短材料有效单条 takeaway 成功”和“超过 30 秒仍 invalidSummary”合同。

Run: `swift test --filter OpenAICompatibleMaterialSummarizerTests`

Expected: compile failure，缺少 `semanticDiversityMass`，或重复样本尚未被识别为 sparse。

### Step 2：实现去重后的语义单元计数

在 `MaterialTranscriptSemantics` 增加纯函数：英文/数字按不区分大小写的连续单词去重，非西文的字母或数字按 Unicode scalar 去重，先移除 Whisper special tokens。`isShortAndSparse` 在原有 duration `<= 30` 前提下改为：

```swift
return semanticMass(transcript) <= shortSparseMaximumSemanticMass
    || semanticDiversityMass(transcript) <= 4
```

该策略只影响 invalidSummary 的错误映射，不得在调用模型前拒绝 transcript，不得改 `hasSemanticContent`，不得把正常 11 秒中文句子“大家好，这是一条测试。”判成 sparse。

Run: `swift test --filter OpenAICompatibleMaterialSummarizerTests`

Expected: 全套 PASS。

### Step 3：相关回归与提交

```bash
swift test --filter 'OpenAICompatibleMaterialSummarizerTests|MaterialDigestCoordinatorTests|MaterialDigestPresentationTests|WhisperKitMaterialTranscriberContractTests'
git diff --check
git add Sources/CalendarApp/Inspiration/MaterialDigestProtocols.swift \
  Tests/CalendarAppTests/OpenAICompatibleMaterialSummarizerTests.swift
git diff --cached --check
git commit -m "fix(inspiration): 友好处理重复短材料"
```

进入 Codex 复核的硬门：有效短摘要仍成功；重复 11 秒样本 invalid 时稳定映射为内容不足；正常中文短句和超过 30 秒材料不被降级；完整测试、release build 与最终打包签名通过。产品实操与用户本人验收仍分开报告。

## Task 14：在固定内存上限内读取大型 B 站页面的早期标题

**结论与边界：** 2026-08-22 最终 App 对公开 B 站视频 `https://www.bilibili.com/video/BV1hgEj6LEVh/` 的元数据获取稳定失败。Apple `URLSession` 实测返回 HTTP 200、`text/html`、约 439,340 bytes，而完整 `</title>` 在约第 1,296 byte 已出现。现有 `URLMetadataResolver` 因 `expectedContentLength > 256_000` 在读取任何内容前直接失败。Task 14 保持 256KB 最大缓冲和无脚本执行，只取消“声明总长度过大就预拒绝”；在固定上限内按小步长检查完整 title，一旦得到标题立即返回。没有完整 title 的超限响应仍必须失败，不能把截断页面当成功，也不能提高默认内存上限。

**Files:**

- Modify: `Sources/CalendarApp/Inspiration/URLMetadataResolver.swift`
- Modify: `Tests/CalendarAppTests/URLMetadataResolverTests.swift`

### Step 1：写大型页面早期标题 RED 合同

扩展测试 fixture，使响应 `Content-Length` 可以大于 resolver 的 `maxBytes`。新增：

```swift
@Test func acceptsCompleteTitleBeforeTheByteLimitEvenWhenDeclaredBodyIsLarger() async throws {
    let prefix = "<html><head><title>B站大型页面</title></head><body>"
    let body = prefix + String(repeating: "x", count: 512)
    let resolver = makeResolver(
        contentType: "text/html; charset=utf-8",
        data: Data(body.utf8),
        maxBytes: 64
    )

    let result = try await resolver.resolve(
        URL(string: "https://www.bilibili.com/video/BV1hgEj6LEVh/")!
    )

    #expect(result.metadata.title == "B站大型页面")
    #expect(result.metadata.fetchStatus == .succeeded)
    #expect(result.resolvedKind == .video)
}
```

保留并强化现有 `rejectsAResponseThatExceedsTheConfiguredByteLimit`：65 bytes 无完整 title、`maxBytes: 64` 仍抛 `.responseTooLarge`。新增 title 闭合标签落在上限之外的 case，仍必须失败。

Run: `swift test --filter URLMetadataResolverTests`

Expected: 新测试因 `expectedContentLength > maxBytes` 预拒绝而 FAIL；原超限测试 PASS。

### Step 2：实现有界早期 title 解析

删除这段预拒绝：

```swift
if http.expectedContentLength > Int64(maxBytes) {
    throw URLMetadataResolverError.responseTooLarge
}
```

保留逐字节 `guard data.count < maxBytes`。设检查步长为 `max(1, min(4_096, maxBytes))`；每累计一个步长，把当前有界 `Data` 解码并调用现有 `extractTitle`。一旦得到非空 title，立即构造 `SourceMetadata(fetchStatus: .succeeded)` 并返回。流自然结束时再做一次最终解析；只有完整 title 缺失时才继续使用现有 host fallback。读取第 `maxBytes + 1` 个 byte 前若仍没有完整 title，抛 `.responseTooLarge`。

为避免分支复制，增加私有纯 helper：

```swift
private static func resolvedResult(
    url: URL,
    title: String,
    classifiedKind: ResolvedSourceKind?
) -> URLMetadataResolveResult
```

helper 只复用当前 `SourceMetadata` 字段，不增加 thumbnail、Cookie、脚本、重定向白名单例外或新网络依赖。不得把 `maxBytes` 提高到 512KB；不得把超限正文落盘；不得在日志打印响应正文。

Run: `swift test --filter URLMetadataResolverTests`

Expected: 全套 PASS。

### Step 3：相关回归与 Grok 候选提交

```bash
swift test --filter 'URLMetadataResolverTests|InspirationWorkspaceViewModelTests|MaterialSourceProviderTests|SourceKindClassifierTests'
git diff --check
git add Sources/CalendarApp/Inspiration/URLMetadataResolver.swift \
  Tests/CalendarAppTests/URLMetadataResolverTests.swift
git diff --cached --check
git commit -m "fix(inspiration): 有界读取大型页面标题"
```

Expected: exit 0；提交只包含两个指定文件。

### Step 4：Codex 最终包真实 B 站回归

Codex 逐行复核 diff，重跑相关与完整测试、release、`Scripts/build-app.sh`、严格 codesign。用新最终 `dist/Jelly.app`、全新 `JELLY_ACCEPTANCE_DATA_DIRECTORY` 和同一公开 B 站 URL 实际捕获：

- 原链接立即持久化，元数据状态从 loading 进入 succeeded；
- 展示真实页面标题而不是裸 URL，不出现“获取失败”；
- 未配置摘要密钥时仍只提示打开设置，不自动提炼；
- 关闭重开后标题、URL、`.video` 来源和未运行状态保持；
- 若页面此时已下线，记录 HTTP 状态并换一个当前匿名可访问的 B 站公开视频，不得用 mock 冒充产品实操。

仅这些证据通过才能报告 B 站元数据产品实操通过；完整提炼、写入笔记和用户本人 9 分验收仍保持 `UNVERIFIED`，直到凭据动作获得用户确认并完成真实旅程。

## Task 15：在进入摘要模型前拒绝明显重复的 Whisper 幻觉转写

**结论与边界：** 2026-08-22 最终 App 对公开 B 站视频 `https://www.bilibili.com/video/BV1hgEj6LEVh/` 的真实提炼已经走到音频兜底：该页面没有原生字幕，WhisperKit 把约 240 秒音频识别为 8 个每隔 30 秒出现一次、内容完全相同的 `Thank you.`。现有 `hasSemanticContent` 只检查字母或数字，因此这份低多样性幻觉被送进 MiniMax-M3，最终暴露成“模型返回的摘要无法校验”。Task 15 只在 Whisper 转写边界识别**至少 3 段、规范化后全部相同且语义多样性极低**的重复噪声，并映射为已有 `.insufficientContent`；不得放松摘要 schema，不得用固定短语黑名单，不得改变 B 站原生字幕或普通长短材料的处理。

**真实根因证据：** 临时诊断测试调用了生产 `RoutedMaterialAcquirer`、真实 B 站音频和隔离验收目录内已下载的 WhisperKit 模型，得到 8 段、80 字符、总时长约 239.98 秒、semantic mass 16、semantic diversity mass 2；8 段文本均为 `Thank you.`。临时诊断代码已删除，不得进入提交。

**Files:**

- Modify: `Sources/CalendarApp/Inspiration/MaterialDigestProtocols.swift`
- Modify: `Sources/CalendarApp/Inspiration/WhisperKitMaterialTranscriber.swift`
- Modify: `Tests/CalendarAppTests/WhisperKitMaterialTranscriberContractTests.swift`

### Step 1：写真实重复转写 RED 合同

在 `WhisperKitMaterialTranscriberContractTests` 使用现有 fake engine 返回 8 个 30 秒 segment，内容为大小写或标点形式略有差异的 `Thank you.`，总跨度约 240 秒。调用生产 transcriber，并断言抛出：

```swift
MaterialTranscriberError.insufficientContent
```

同时先写两条回归合同：

- 只有 2 个相同 segment 时不触发重复噪声规则，仍返回 transcript；
- 至少 3 个内容有真实差异的长 segment 正常返回，不能因为持续时间长或总词数少被拒绝。

Run: `swift test --filter WhisperKitMaterialTranscriberContractTests`

Expected: 8 段重复样本当前错误地返回 transcript，RED 失败；既有测试与两条回归合同保持通过。

### Step 2：增加窄边界的重复噪声判定

在 `MaterialTranscriptSemantics` 增加纯函数，例如：

```swift
static func isLikelyRepetitiveTranscriptionNoise(
    _ transcript: TimestampedTranscript
) -> Bool
```

实现要求：

- 先移除 Whisper special tokens；
- 对每个非空 segment 做小写化，并只保留 Unicode 字母和数字，消除空白与标点差异；
- 至少有 3 个语义 segment；
- 所有语义 segment 的规范化文本完全相同；
- `semanticDiversityMass(transcript) <= 4`，避免把一段被切成多段的正常长句误杀；
- 不使用 `Thank you`、语言、网站或时长黑名单，不修改已有 `isShortAndSparse` 合同。

在 `WhisperKitMaterialTranscriber.transcribe` 完成 segment 规范化后、返回 `TimestampedTranscript` 前，组合已有语义检查：

```swift
let transcript = TimestampedTranscript(segments: normalized)
guard MaterialTranscriptSemantics.hasSemanticContent(transcript),
      !MaterialTranscriptSemantics.isLikelyRepetitiveTranscriptionNoise(transcript)
else {
    throw MaterialTranscriberError.insufficientContent
}
return transcript
```

这条规则只约束 Whisper 输出，并在调用 MiniMax 前结束，避免无价值请求；B 站原生字幕不经过该 transcriber，因此不受影响。

Run: `swift test --filter WhisperKitMaterialTranscriberContractTests`

Expected: 新旧合同全部 PASS。

### Step 3：相关回归与 Grok 候选提交

```bash
swift test --filter 'WhisperKitMaterialTranscriberContractTests|MaterialDigestCoordinatorTests|OpenAICompatibleMaterialSummarizerTests'
git diff --check
git add Sources/CalendarApp/Inspiration/MaterialDigestProtocols.swift \
  Sources/CalendarApp/Inspiration/WhisperKitMaterialTranscriber.swift \
  Tests/CalendarAppTests/WhisperKitMaterialTranscriberContractTests.swift
git diff --cached --check
git commit -m "fix(inspiration): 识别重复转写噪声"
```

Expected: exit 0；Grok 提交只包含三个指定文件，不修改计划、构建产物、凭据、验收数据或临时诊断代码，不 push、不 merge。

### Step 4：Codex 独立复核与最终 App 产品实操

Codex 逐行检查 Grok 候选 diff，先重跑 focused/related tests，再执行完整 `swift test`、release build、`Scripts/build-app.sh` 与严格 codesign。随后使用同一个隔离数据目录和新打包的 `dist/Jelly.app`：

- 对上述 B 站样本点“重试”，应稳定得到现有友好状态“没有识别到足够可提炼的内容”，不再出现 `invalidSummary`；
- 确认原始链接、真实标题和失败状态持久化，关闭重开后仍可恢复；
- 另选一个当时匿名可访问、含有可识别真实讲话的 B 站视频，走完“点击提炼 → 摘要成功 → 用户点击写入笔记 → 原链接在笔记首行 → 摘要结构可编辑 → 重启持久化”；
- 再确认此前小宇宙摘要与笔记仍然存在，跨来源没有回归。

只有前两项完成可报告本缺陷的产品实操通过；只有有意义的 B 站成功样本、小宇宙回归和最终 App 完整旅程都完成，才可报告灵感材料提炼主流程的产品实操通过。视觉质感、等待手感与“用户 9 分体验”仍为 `UNVERIFIED`，必须由用户本人使用后确认。

## Task 16：让中文 Jelly 的派生摘要统一使用简体中文

**结论与边界：** 2026-08-22 最终 App 已对 B 站真实英文讲话样本 `https://www.bilibili.com/video/BV1YY4y1A7CP/` 完成 Whisper 转写、MiniMax-M3 摘要、写入笔记与可编辑展示，但 thesis、takeaways 和 chapters 全部跟随英文原文输出。当前 system prompt 虽然使用中文，却没有明确规定派生摘要语言。Jelly 当前产品界面和状态文案统一为中文，因此 Task 16 要求 thesis、takeaways、chapters.title、chapters.points 和 dropped 使用简体中文；quotes.text 必须保留原文语言和原句，quotes.speaker 保留原文姓名，完整 transcript 继续保留原语言。不得翻译引用后冒充原话，不得改变 Whisper 语言检测，不得用中文字符比例校验拒绝合法结果。

**Files:**

- Modify: `Sources/CalendarApp/Inspiration/OpenAICompatibleMaterialSummarizer.swift`
- Modify: `Tests/CalendarAppTests/OpenAICompatibleMaterialSummarizerTests.swift`

### Step 1：写摘要语言 RED 合同

在 `OpenAICompatibleMaterialSummarizerTests` 新增生产请求合同，用英文 transcript 和 `.video` source 调用摘要器，捕获发送给 transport 的 JSON body，并读取 system message。断言该消息必须同时包含以下不可误解的约束：

- thesis、takeaways、chapters.title、chapters.points、dropped 使用简体中文；
- quotes.text 保留原文，不得翻译；
- transcript 和专有名词不因摘要语言要求被改写。

测试不得只搜索“中文”两个字；要断言派生字段和原文引用两个相反边界都存在。transport 返回一份合法中文派生摘要与英文原文 quote，确认现有 evidence 校验仍通过。

Run: `swift test --filter OpenAICompatibleMaterialSummarizerTests`

Expected: 当前 system prompt 没有输出语言要求，新合同 RED 失败。

### Step 2：补充窄边界的 system prompt

在 `OpenAICompatibleMaterialSummarizer.systemPrompt(for:)` 的通用合同中增加一段明确规则：

```text
面向 Jelly 用户的派生内容必须使用简体中文：thesis、takeaways、chapters.title、chapters.points、dropped 均用简体中文，必要的专有名词可保留原文。quotes.text 是原文证据，必须保持文稿中的原语言和原句，不得翻译或改写；quotes.speaker 保留原文姓名。完整文稿也保持原语言。
```

只改 system prompt，不改 JSON schema、字段上限、证据验证、transport、endpoint、模型参数或原文转写。不要在客户端用中文字符比例做启发式校验，避免技术名词、姓名和合法短摘要被误拒绝。

Run: `swift test --filter OpenAICompatibleMaterialSummarizerTests`

Expected: 全套 PASS。

### Step 3：相关回归与 Grok 候选提交

```bash
swift test --filter 'OpenAICompatibleMaterialSummarizerTests|MaterialDigestCoordinatorTests|MaterialDigestPresentationTests'
git diff --check
git add Sources/CalendarApp/Inspiration/OpenAICompatibleMaterialSummarizer.swift \
  Tests/CalendarAppTests/OpenAICompatibleMaterialSummarizerTests.swift
git diff --cached --check
git commit -m "fix(inspiration): 统一输出中文摘要"
```

Expected: exit 0；Grok 提交只包含两个指定文件，不修改 Task 15、schema、构建产物、凭据或验收数据，不 push、不 merge。

### Step 4：Codex 独立复核与真实英文材料门禁

Codex 逐行检查 diff，重跑 focused、related、完整测试、release、最终 App 打包和严格签名。使用同一隔离凭据命名空间、新打包的 `dist/Jelly.app` 和另一条当时匿名可访问的英文讲话 B 站视频完成：

- 捕获后仍不自动提炼，必须由用户点击“提炼这个链接”；
- transcript 与 quotes.text 保持英文原文；
- thesis、takeaways、chapters.title、chapters.points 和 dropped 使用简体中文；
- 用户点击“写入笔记”后，原链接在首行，中文派生摘要可编辑，英文原文引用不被翻译；
- 关闭重开后结果、笔记和 Task 15 的友好失败状态均持久化，小宇宙既有笔记不回归。

只有真实 MiniMax-M3 最终 App 旅程满足这些条件，才可报告跨语言 B 站提炼的产品实操通过；用户本人是否认为达到 9 分仍保持 `UNVERIFIED`。
