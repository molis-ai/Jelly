# Jelly 多格式材料提炼 C：小红书与 10 分验收 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 仅在计划 A/B 已通过 Codex review 后执行。Grok Worker 负责实现和候选证据，Codex 独立检查实际 diff、工程门禁和最终 App 实操；用户本人未认可前，用户验收保持 `UNVERIFIED`。

**Goal:** 用薄平台适配器直接支持公开小红书视频与图文笔记，并完成平台失败回退、真实 MiniMax 摘要、最终 App 多格式实操和用户 10 分验收候选。

**Architecture:** `XiaohongshuMaterialAcquirer` 只解析公开页面状态，输出正文 blocks、图片资产和视频资产；图片/视频复用计划 B 的 OCR、AVFoundation 和 Whisper。平台页面变化被隔离为 adapter failure，标准化 snapshot、长材料摘要、证据、恢复和笔记写入不随平台改变。

**Tech Stack:** Swift 6.3、Foundation/URLSession、JSON、Vision、AVFoundation、WhisperKit、MiniMax OpenAI-compatible endpoint、swift-testing、macOS 14+。

**Spec:** `docs/superpowers/specs/2026-08-24-universal-material-digest-design.md`

## Global Constraints

- 必须先完成并 review 计划 A、B；不得在 transcript-only 或未迁移 schema 上直接塞小红书分支。
- 第一阶段只支持公开 `xiaohongshu.com/explore/<id>`、`xiaohongshu.com/discovery/item/<id>` 和经过真实验证的官方分享重定向。
- 不读取浏览器 Cookie，不登录、不绕过风控/验证码，不抓私密、付费或受限笔记。
- 用户 rawURL 原样保存；真实 `xsec_token` 不得进入测试 fixture、代码、计划、日志、诊断、材料快照、commit message 或验收报告。
- 日志和错误只允许记录去 query/fragment 的安全 URL 描述。
- 页面只得到标题/封面/metadata 时不生成摘要；描述正文或已处理图片/视频内容足够时才通过门禁。
- 视频笔记合并公开正文、话题 metadata、音轨转写和代表性画面 OCR；图文笔记处理全部公开图片。
- 任一资产失败时使用 typed partial coverage；全部正文/媒体不足时失败并提供粘贴/文件恢复动作。
- 不把 yt-dlp、Python、Playwright、WebView 自动化或后台服务加入生产路径。
- MiniMax 密钥只能通过本机 `appkey exec minimax -- sh -c '...'` 或 App Keychain 使用；不得读取 `~/.appkey/`。
- 每个 Task 严格 RED → 预期失败 → 最小 GREEN → focused tests → `git diff --check`。
- 没有提交授权时停在 staged 前；不得自行推送、合并、发布。
- 工程、产品实操、用户验收三层结论分开；自动点击、fixture 和 live probe 不代替用户主观体验。

## File Map

- Create `Sources/CalendarApp/Inspiration/XiaohongshuPageParser.swift`: balanced JSON、公开 note payload、资源候选。
- Create `Sources/CalendarApp/Inspiration/XiaohongshuMaterialAcquirer.swift`: 安全页面获取和 composite acquisition。
- Modify `Sources/CalendarApp/Inspiration/MaterialSourceResolver.swift`: 小红书 descriptor。
- Modify `Sources/CalendarApp/Inspiration/SourceKindClassifier.swift`: 展示分类 `.socialPost`。
- Modify `Sources/CalendarApp/Inspiration/MaterialDigestProtocols.swift`: composite block/image/media plan。
- Modify `Sources/CalendarApp/Inspiration/MaterialDigestCoordinator.swift`: 合并小红书正文、OCR 和 media batch。
- Modify `Sources/CalendarApp/Inspiration/URLMetadataResolver.swift`: 小红书标题/封面 metadata，不执行摘要。
- Modify `Sources/CalendarApp/Inspiration/MaterialDigestSection.swift`: partial 和平台恢复动作。
- Modify `Sources/CalendarApp/Inspiration/InspirationSplitView.swift`: 粘贴/文件恢复交互。
- Modify `Sources/CalendarApp/AppEnvironment.swift`: 注册小红书 adapter。
- Create `Tests/CalendarAppTests/XiaohongshuPageParserTests.swift`。
- Create `Tests/CalendarAppTests/XiaohongshuMaterialAcquirerTests.swift`。
- Modify `Tests/CalendarAppTests/MaterialSourceResolverTests.swift`。
- Modify `Tests/CalendarAppTests/SourceKindClassifierTests.swift`。
- Modify `Tests/CalendarAppTests/MaterialDigestCoordinatorTests.swift`。
- Modify `Tests/CalendarAppTests/MaterialDigestPresentationTests.swift`。
- Modify `Tests/CalendarAppTests/MaterialSourceProviderLiveTests.swift`。
- Create `docs/acceptance/2026-08-24-universal-material-digest-candidate.md`: 只记录无秘密证据和三层结论。

---

### Task 1: 精确识别小红书公开笔记 URL

**Files:**
- Modify: `Sources/CalendarApp/Inspiration/SourceKindClassifier.swift`
- Modify: `Sources/CalendarApp/Inspiration/MaterialSourceResolver.swift`
- Modify: `Tests/CalendarAppTests/SourceKindClassifierTests.swift`
- Modify: `Tests/CalendarAppTests/MaterialSourceResolverTests.swift`

**Interfaces:**
- Produces: `MaterialSourceDescriptor.Kind.xiaohongshuNote(noteID: String)`。
- Produces: 展示 kind `.socialPost`；descriptor 保留平台身份和 note ID。

- [ ] **Step 1: 写 host/path 欺骗 RED 表格**

```swift
@Test func classifiesOnlyPublicXiaohongshuNotePaths() {
    let cases: [(String, ResolvedSourceKind?, Bool)] = [
        ("https://www.xiaohongshu.com/explore/6a7b2b1900000000220316a9", .socialPost, true),
        ("https://www.xiaohongshu.com/discovery/item/6a7b2b1900000000220316a9", .socialPost, true),
        ("https://www.xiaohongshu.com/user/profile/123", nil, false),
        ("https://fake-xiaohongshu.com/explore/1", nil, false),
        ("https://xiaohongshu.com.evil.test/explore/1", nil, false),
        ("http://www.xiaohongshu.com/explore/1", nil, false)
    ]
    for (raw, kind, supported) in cases {
        let url = URL(string: raw)!
        #expect(SourceKindClassifier.classify(url) == kind)
        #expect(MaterialSourceResolver.resolve(.urlFixture(url))?.descriptor.isSupported == supported)
    }
}
```

- [ ] **Step 2: 运行 RED**

Run: `swift test --filter 'SourceKindClassifierTests|MaterialSourceResolverTests'`

Expected: 小红书返回 nil/public article，没有 `.xiaohongshuNote`。

- [ ] **Step 3: 实现精确 allowlist**

host 仅接受 `xiaohongshu.com` 或其真实子域；scheme 必须 HTTPS；path components 精确匹配 `explore/<nonempty-id>` 或 `discovery/item/<nonempty-id>`。query 不参与 note ID，不能被 host/path 解码绕过。

- [ ] **Step 4: 转绿和已有平台回归**

Run: `swift test --filter 'SourceKindClassifierTests|MaterialSourceResolverTests'`

Expected: PASS；B 站、小宇宙、普通文章分类不变。

- [ ] **Step 5: diff 自检和候选提交**

Run: `git diff --check`

Candidate commit:

```bash
git add Sources/CalendarApp/Inspiration/SourceKindClassifier.swift \
  Sources/CalendarApp/Inspiration/MaterialSourceResolver.swift \
  Tests/CalendarAppTests/SourceKindClassifierTests.swift \
  Tests/CalendarAppTests/MaterialSourceResolverTests.swift
git commit -m "feat(inspiration): 识别小红书公开笔记"
```

---

### Task 2: 从公开页面安全解析视频和图文 payload

**Files:**
- Create: `Sources/CalendarApp/Inspiration/XiaohongshuPageParser.swift`
- Create: `Tests/CalendarAppTests/XiaohongshuPageParserTests.swift`
- Create: `Tests/CalendarAppTests/Fixtures/xiaohongshu-video-note.html`
- Create: `Tests/CalendarAppTests/Fixtures/xiaohongshu-image-note.html`
- Create: `Tests/CalendarAppTests/Fixtures/xiaohongshu-structure-changed.html`

**Interfaces:**
- Produces: `XiaohongshuNotePayload(noteID:kind:title:body:tags:images:video:)`。
- Produces: `XiaohongshuPageParser.parse(html:expectedNoteID:) throws -> XiaohongshuNotePayload`。

- [ ] **Step 1: 写脱敏 fixture RED 测试**

```swift
@Test func parsesVideoNoteFromInitialStateWithoutGreedyScriptCapture() throws {
    let payload = try XiaohongshuPageParser.parse(
        html: fixtureString("xiaohongshu-video-note.html"),
        expectedNoteID: "video-note-id"
    )
    #expect(payload.kind == .video)
    #expect(payload.body == "公开视频正文")
    #expect(payload.tags == ["效率", "学习"])
    #expect(payload.video?.candidateURLs.first?.scheme == "https")
}

@Test func parsesAllImageAssetsAndRejectsWrongNoteID() throws {
    let html = fixtureString("xiaohongshu-image-note.html")
    let payload = try XiaohongshuPageParser.parse(html: html, expectedNoteID: "image-note-id")
    #expect(payload.kind == .image)
    #expect(payload.images.count == 3)
    #expect(throws: XiaohongshuPageParserError.noteMismatch) {
        _ = try XiaohongshuPageParser.parse(html: html, expectedNoteID: "other")
    }
}
```

- [ ] **Step 2: 运行 RED**

Run: `swift test --filter XiaohongshuPageParserTests`

Expected: parser/payload 不存在。

- [ ] **Step 3: 实现 balanced JSON 提取和有界递归查找**

从 `window.__INITIAL_STATE__` 赋值后的第一个 `{` 开始按字符串转义、括号深度扫描到对应 `}`，不得使用 `.*` 贪婪正则跨脚本。JSON decode 后在已知 `noteDetailMap`/`note` 路径和有界递归深度内查找 expected note ID。只接受 HTTPS 资源 URL；按页面顺序去重图片和视频候选。

```swift
struct XiaohongshuNotePayload: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case video, image }
    let noteID: String
    let kind: Kind
    let title: String?
    let body: String?
    let tags: [String]
    let images: [MaterialImageAsset]
    let video: MaterialVideoAsset?
}
```

fixture 必须人工脱敏：ID、作者、URL host/path 可保持结构但不得含用户分享 token、Cookie、昵称或真实私有数据。

- [ ] **Step 4: 转绿和恶意 HTML 回归**

Run: `swift test --filter XiaohongshuPageParserTests`

Expected: 视频、图文、escaped JSON、附加 script、错误 ID、missing state、`javascript:`/HTTP 资源测试全部 PASS。

- [ ] **Step 5: 敏感信息扫描和候选提交**

Run: `rg -n 'xsec_token|xsec_source|Cookie|Bearer |sk-' Tests/CalendarAppTests/Fixtures Sources/CalendarApp/Inspiration/XiaohongshuPageParser.swift || true`

Expected: 无匹配。

Candidate commit:

```bash
git add Sources/CalendarApp/Inspiration/XiaohongshuPageParser.swift \
  Tests/CalendarAppTests/XiaohongshuPageParserTests.swift \
  Tests/CalendarAppTests/Fixtures/xiaohongshu-*.html
git commit -m "feat(inspiration): 解析小红书公开笔记页面"
```

---

### Task 3: 获取小红书 composite 材料而不复制格式逻辑

**Files:**
- Create: `Sources/CalendarApp/Inspiration/XiaohongshuMaterialAcquirer.swift`
- Modify: `Sources/CalendarApp/Inspiration/MaterialDigestProtocols.swift`
- Modify: `Sources/CalendarApp/Inspiration/MaterialSourceProviders.swift`
- Create: `Tests/CalendarAppTests/XiaohongshuMaterialAcquirerTests.swift`
- Modify: `Tests/CalendarAppTests/MaterialSourceProviderTests.swift`

**Interfaces:**
- Produces: `MaterialCompositeAcquisition(seedBlocks:images:remoteMedia:expectedAssetCount:provenance:)`。
- Produces: `XiaohongshuMaterialAcquirer.acquire(_:) async throws -> MaterialCompositeAcquisition`。

- [ ] **Step 1: 写 headers、正文和资源 RED 测试**

```swift
@Test func videoAcquisitionUsesSafeHeadersAndReturnsCompositePlan() async throws {
    let harness = XiaohongshuAcquirerHarness.video()
    let acquisition = try await harness.acquirer.acquire(.xiaohongshuFixture())
    #expect(acquisition.seedBlocks.map(\.role) == [.metadata, .body, .metadata])
    #expect(acquisition.remoteMedia?.kind == .video)
    #expect(acquisition.images.isEmpty)
    #expect(harness.lastRequestHeaders["Cookie"] == nil)
    #expect(harness.lastRequestHeaders["Referer"] == nil)
}

@Test func imageAcquisitionKeepsAllImagesAndDoesNotTreatTitleAsBody() async throws {
    let acquisition = try await XiaohongshuAcquirerHarness.image().acquirer.acquire(.xiaohongshuFixture())
    #expect(acquisition.images.count == 3)
    #expect(acquisition.seedBlocks.first(where: { $0.text == "页面标题" })?.role == .metadata)
}
```

- [ ] **Step 2: 运行 RED**

Run: `swift test --filter 'XiaohongshuMaterialAcquirerTests|MaterialSourceProviderTests'`

Expected: composite type/acquirer 不存在。

- [ ] **Step 3: 实现公开页面 acquirer**

页面 GET 使用 desktop User-Agent、Accept HTML、不带 Cookie；final URL 必须仍由 resolver 识别为相同 note ID。正文为 body，title/tags 为 metadata。视频候选 request headers 只包含最小 User-Agent 和页面 Referer；图片按原序交 ImageMaterialExtractor。

```swift
struct MaterialCompositeAcquisition: Equatable, Sendable {
    let seedBlocks: [MaterialBlock]
    let images: [MaterialImageAsset]
    let remoteMedia: RemoteMediaAsset?
    let expectedAssetCount: Int
    let provenance: MaterialAcquisitionProvenance
}
```

403/登录页映射 `.restrictedSource`；missing state/资源映射 `.sourceUnavailable`；不回退 title-only blocks。

- [ ] **Step 4: 转绿和 HTTP 安全回归**

Run: `swift test --filter 'XiaohongshuMaterialAcquirerTests|MaterialSourceProviderTests'`

Expected: PASS；SSRF、redirect、大小上限、取消继续通过。

- [ ] **Step 5: diff 自检和候选提交**

Run: `git diff --check`

Candidate commit:

```bash
git add Sources/CalendarApp/Inspiration/XiaohongshuMaterialAcquirer.swift \
  Sources/CalendarApp/Inspiration/MaterialDigestProtocols.swift \
  Sources/CalendarApp/Inspiration/MaterialSourceProviders.swift \
  Tests/CalendarAppTests/XiaohongshuMaterialAcquirerTests.swift \
  Tests/CalendarAppTests/MaterialSourceProviderTests.swift
git commit -m "feat(inspiration): 获取小红书公开视频与图片"
```

---

### Task 4: Coordinator 合并小红书正文、OCR 和视频内容

**Files:**
- Modify: `Sources/CalendarApp/Inspiration/MaterialDigestCoordinator.swift`
- Modify: `Tests/CalendarAppTests/MaterialDigestCoordinatorTests.swift`

**Interfaces:**
- Consumes: `MaterialCompositeAcquisition`、计划 B 的 Image/Media extractors。
- Produces: 单一 MaterialSnapshot，按 seed → image order → media order 稳定排列并重新编号 locator。

- [ ] **Step 1: 写视频/图文/partial RED 测试**

```swift
@Test func xiaohongshuVideoCombinesBodyTranscriptAndFrameOCRBeforeSummary() async throws {
    let h = try await CoordinatorXHSHarness.video()
    await h.coordinator.start(inspirationID: h.id, mode: .refreshSource)
    #expect(await waitUntil { h.digest.result != nil })
    #expect(h.snapshot.blocks.map(\.role) == [.metadata, .body, .metadata, .transcript, .ocr])
    #expect(h.summarizer.receivedSnapshot == h.snapshot)
}

@Test func oneFailedImageCreatesPartialResultAndKeepsFailureVisible() async throws {
    let h = try await CoordinatorXHSHarness.images(oneFailure: true)
    await h.coordinator.start(inspirationID: h.id, mode: .refreshSource)
    #expect(await waitUntil { h.digest.result != nil })
    #expect(h.digest.preparedSnapshot?.coverage == .partial(
        processed: 2, expected: 3, issues: [.ocrFailed]
    ))
}
```

- [ ] **Step 2: 运行 RED**

Run: `swift test --filter MaterialDigestCoordinatorTests`

Expected: coordinator 不认识 composite acquisition。

- [ ] **Step 3: 实现合并、阶段和质量门禁**

视频使用 `.transcribing`/`.recognizingImages` 真实阶段；图文使用 `.recognizingImages`。body 本身足够但图片失败时允许 partial；只有 metadata 或空 OCR 时 insufficient。合并后统一运行重复噪声过滤和 content fingerprint，先 save snapshot 再摘要。

视频无可用音轨但正文 + OCR 足够时 partial 成功并包含 `.transcriptionFailed`；正文也不足时失败。

- [ ] **Step 4: 转绿并验证重试不重复平台获取**

Run: `swift test --filter MaterialDigestCoordinatorTests`

Expected: PASS；模型失败后 retry 复用 snapshot，XHS page/image/video invocation counts 不增加。

- [ ] **Step 5: diff 自检和候选提交**

Run: `git diff --check`

Candidate commit:

```bash
git add Sources/CalendarApp/Inspiration/MaterialDigestCoordinator.swift \
  Tests/CalendarAppTests/MaterialDigestCoordinatorTests.swift
git commit -m "feat(inspiration): 合并小红书多模态文字材料"
```

---

### Task 5: 元数据、状态和失败恢复做到可行动

**Files:**
- Modify: `Sources/CalendarApp/Inspiration/URLMetadataResolver.swift`
- Modify: `Sources/CalendarApp/Inspiration/MaterialDigestSection.swift`
- Modify: `Sources/CalendarApp/Inspiration/InspirationSplitView.swift`
- Modify: `Sources/CalendarApp/Inspiration/InspirationViewModel.swift`
- Modify: `Tests/CalendarAppTests/URLMetadataResolverTests.swift`
- Modify: `Tests/CalendarAppTests/MaterialDigestPresentationTests.swift`
- Modify: `Tests/CalendarAppTests/InspirationWorkspaceViewModelTests.swift`

**Interfaces:**
- Produces: 小红书 `.socialPost` 元数据展示；metadata failure 不改变 rawURL。
- Produces: `.restrictedSource/.sourceUnavailable/.insufficientContent` 对应恢复动作。

- [ ] **Step 1: 写 10 分恢复 RED 测试**

```swift
@Test func restrictedXHSKeepsRawURLAndOffersThreeConcreteActions() {
    let p = MaterialDigestPresentation.project(
        inspiration: .xiaohongshuFixture(), digest: .failed(.restrictedSource), operatorAvailable: true
    )
    #expect(p.statusText == "小红书限制了公开内容读取，原始链接仍然保留。")
    #expect(p.recoveryActions == [.pasteText, .chooseFile, .retrySource])
    #expect(p.primaryActionTitle == nil)
}

@Test func partialXHSExplainsMissingImagesWithoutHidingSummary() {
    let p = MaterialDigestPresentation.project(
        inspiration: .xiaohongshuFixture(), digest: .succeededPartialImages(), operatorAvailable: true
    )
    #expect(p.thesis != nil)
    #expect(p.coverageText == "基于部分内容：3 张图片中 2 张已识别")
}
```

- [ ] **Step 2: 运行 RED**

Run: `swift test --filter 'URLMetadataResolverTests|MaterialDigestPresentationTests|InspirationWorkspaceViewModelTests'`

Expected: 小红书没有专用文案/恢复动作，或 digest section 对 socialPost 隐藏。

- [ ] **Step 3: 实现低打扰状态和用户确认回退**

统一主操作仍为“提炼这份材料”。受限时显示粘贴正文、选择截图/媒体、重试读取；选择补充来源前展示一次明确确认，更新 Inspiration source checksum，使旧 result 只读过期。partial 结果保留摘要和覆盖文案；不足内容不显示“提炼完成”。

URL metadata 只读取公开 title/thumbnail；失败写 `.failed`，不把来源改成 article，不启动 digest。

- [ ] **Step 4: 转绿并跑笔记写入回归**

Run: `swift test --filter 'URLMetadataResolverTests|MaterialDigestPresentationTests|InspirationWorkspaceViewModelTests'`

Expected: PASS；partial coverage 写入笔记不会丢；原链接第一块；重复写入幂等。

- [ ] **Step 5: diff 自检和候选提交**

Run: `git diff --check`

Candidate commit:

```bash
git add Sources/CalendarApp/Inspiration/URLMetadataResolver.swift \
  Sources/CalendarApp/Inspiration/MaterialDigestSection.swift \
  Sources/CalendarApp/Inspiration/InspirationSplitView.swift \
  Sources/CalendarApp/Inspiration/InspirationViewModel.swift \
  Tests/CalendarAppTests/URLMetadataResolverTests.swift \
  Tests/CalendarAppTests/MaterialDigestPresentationTests.swift \
  Tests/CalendarAppTests/InspirationWorkspaceViewModelTests.swift
git commit -m "feat(inspiration): 完善小红书失败恢复体验"
```

---

### Task 6: 注册生产适配器并增加显式 live probe

**Files:**
- Modify: `Sources/CalendarApp/AppEnvironment.swift`
- Modify: `Tests/CalendarAppTests/MaterialSourceProviderLiveTests.swift`
- Modify: `Tests/CalendarAppTests/AppEnvironmentWorkspaceCutoverTests.swift`

**Interfaces:**
- Produces: production router 注册 `XiaohongshuMaterialAcquirer`。
- Produces: live probe 只在 `JELLY_RUN_LIVE_MATERIAL_PROBE=1` 且 `JELLY_XHS_LIVE_URL` 存在时运行。

- [ ] **Step 1: 写 production/live RED 合同**

```swift
@Test(.enabled(if: ProcessInfo.processInfo.environment["JELLY_RUN_LIVE_MATERIAL_PROBE"] == "1"))
func liveXiaohongshuURLYieldsCompositeMaterial() async throws {
    let raw = try #require(ProcessInfo.processInfo.environment["JELLY_XHS_LIVE_URL"])
    let source = try #require(MaterialSourceResolver.resolve(.urlFixture(URL(string: raw)!)))
    let result = try await RoutedMaterialAcquirer().acquire(source)
    guard case let .composite(value) = result else {
        Issue.record("expected xiaohongshu composite acquisition")
        return
    }
    print("LIVE_PROBE_RAN platform=xiaohongshu blocks=\(value.seedBlocks.count) assets=\(value.expectedAssetCount)")
    #expect(!value.seedBlocks.isEmpty || value.expectedAssetCount > 0)
}
```

- [ ] **Step 2: 运行默认测试确认 live probe 跳过**

Run: `swift test --filter MaterialSourceProviderLiveTests`

Expected: exit 0；未提供 env 时 XHS live test skip，不含硬编码 URL/token。

- [ ] **Step 3: 注册生产 adapter 并运行用户样例 probe**

用户样例 URL 只通过当前 shell 的 `JELLY_XHS_LIVE_URL` 注入，不写命令历史文件、测试或报告。执行前用安全方式确认环境变量存在；输出不得打印原 URL/query。

Run pattern:

```bash
JELLY_RUN_LIVE_MATERIAL_PROBE=1 \
JELLY_XHS_LIVE_URL="$JELLY_XHS_LIVE_URL" \
swift test --filter liveXiaohongshuURLYieldsCompositeMaterial
```

Expected: `LIVE_PROBE_RAN platform=xiaohongshu ...`；不打印 token。若页面要求登录，记录 restricted，不绕过。

- [ ] **Step 4: 运行生产装配回归**

Run: `swift test --filter 'AppEnvironmentWorkspaceCutoverTests|MaterialSourceProviderLiveTests'`

Expected: 默认无网络 PASS/skip；生产无 fixture provider。

- [ ] **Step 5: diff 自检和候选提交**

Run: `git diff --check`

Run: `rg -n 'xsec_token|JELLY_XHS_LIVE_URL=.*https|CBB0' Sources Tests docs || true`

Expected: 无真实 URL/token。

Candidate commit:

```bash
git add Sources/CalendarApp/AppEnvironment.swift \
  Tests/CalendarAppTests/MaterialSourceProviderLiveTests.swift \
  Tests/CalendarAppTests/AppEnvironmentWorkspaceCutoverTests.swift
git commit -m "feat(inspiration): 接入小红书生产适配器"
```

---

### Task 7: 用本机 appkey 和 MiniMax 做真实结构化摘要

**Files:**
- Modify tests only if the real run exposes a deterministic contract defect; do not add a one-off bypass。
- Create: `docs/acceptance/2026-08-24-universal-material-digest-candidate.md`

**Interfaces:**
- Consumes: existing Digest settings/Keychain and `OpenAICompatibleMaterialSummarizer`。
- Produces: 无密钥、无原 URL query 的真实 MiniMax 证据记录。

- [ ] **Step 1: 先运行离线 MiniMax request contract**

Run: `swift test --filter 'OpenAICompatibleMaterialSummarizerTests|HierarchicalMaterialSummarizerTests'`

Expected: PASS，V3 JSON schema、中文派生字段、原文引用和 evidence 全部通过。

- [ ] **Step 2: 通过 appkey 同一 shell 运行真实调用**

严禁读取 `~/.appkey/`。只允许：

```bash
appkey exec minimax -- sh -c '
  test -n "$MINIMAX_API_KEY"
  # 在同一 shell 启动既有安全 acceptance harness；只传 endpoint/model/key 到进程环境或隔离 Keychain
'
```

默认 endpoint `https://api.minimaxi.com/anthropic`、模型 `MiniMax-M3`；若 Jelly 当前使用 OpenAI-compatible `/chat/completions` 而该 endpoint 协议不同，使用已经验证的 MiniMax OpenAI-compatible endpoint 配置，不改生产协议去迁就一次测试。任何端点判断必须以真实响应为证据。

Expected: 返回 V3 结构化摘要；thesis/takeaways/chapters/dropped 为简体中文；quote 原语言；所有 evidence IDs 存在。输出和文档不含 key、Authorization、完整用户 URL 或模型原始响应。

- [ ] **Step 3: 失败时只做根因修复**

允许修复：协议映射、JSON schema 兼容、长度预算、字段本地校验。禁止：关闭 schema、接受自由文本、伪造 evidence、把真实 key 写 fixture、为 MiniMax 特判跳过 Validator。

每个修复先新增可复现 RED fixture，再最小 GREEN，再重新运行真实调用。

- [ ] **Step 4: 写无秘密候选证据**

文档只记录：观察日期、App commit、模型标识、输入类型（不含完整 URL）、是否工程/真实调用通过、覆盖边界、失败与恢复、用户验收 `UNVERIFIED`。不得复制完整原文或模型长响应。

- [ ] **Step 5: diff 与敏感信息审计**

Run: `git diff --check`

Run: `rg -n 'MINIMAX_API_KEY=|Authorization:|Bearer |xsec_token|CBB0|sk-' Sources Tests docs || true`

Expected: 无秘密。

Candidate commit:

```bash
git add docs/acceptance/2026-08-24-universal-material-digest-candidate.md
git commit -m "test(inspiration): 记录真实多格式提炼证据"
```

---

### Task 8: 完整工程门禁、最终 App 实操和 10 分候选评分

**Files:**
- Modify: `docs/acceptance/2026-08-24-universal-material-digest-candidate.md`
- No production code unless a reproduced acceptance defect receives a RED test first。

**Interfaces:**
- Produces: 工程验证、产品实操、用户验收三层报告。

- [ ] **Step 1: 运行完整工程门禁**

Run: `swift test`

Expected: exit 0。

Run: `swift build -c release`

Expected: exit 0。

Run: `Scripts/build-app.sh`

Expected: exit 0，生成最终 `dist/Jelly.app`。

Run: `codesign --verify --deep --strict --verbose=2 dist/Jelly.app`

Expected: valid on disk and satisfies Designated Requirement。

- [ ] **Step 2: 使用隔离但非空数据启动最终 App**

设置新的明确验收目录，确认 Workspace、Keychain service、模型目录和 endpoint/model 偏好均由该目录隔离；不得复用或覆盖正式 Jelly 数据。只打开刚构建的 `dist/Jelly.app`，不是 `.build/debug`。

- [ ] **Step 3: 逐一实操 10 条真实旅程**

1. 长文字；
2. 公共中文文章；
3. 用户提供的小红书视频笔记；
4. 小红书多图文字笔记；
5. B 站公开视频；
6. 小宇宙公开单集；
7. 本地中英文音频和视频；
8. 数字 PDF 与扫描 PDF；
9. 平台受限后粘贴/文件恢复；
10. 长材料、取消、失败重试、重启和确认写入笔记。

每条记录：原输入是否立即保存、点击到可见反馈、真实阶段、摘要依据、partial/失败状态、重试是否复用 snapshot、原始来源、写入笔记和重启结果。

- [ ] **Step 4: 测量本地反馈而不是外部耗时**

用最终 App 可观察事件记录：主操作到 processing state ≤ 300 ms；取消到 visible cancelled ≤ 1 s。网络、OCR、Whisper、模型耗时单独记录，不混入本地反馈。

- [ ] **Step 5: 按硬门和 10 项体验评分**

硬失败任一出现即候选不通过：丢原始来源、只凭 metadata 生成摘要、partial 冒充完整、取消后写回、重试重复昂贵提取、证据不存在、无确认写笔记、写入重复、密钥/token 泄漏、生产 fixture、V4→V5 数据损坏。

10 项体验逐项 0/0.5/1：统一入口、即时反馈、诚实进度、摘要质量、原文依据、部分内容透明、失败可恢复、重试/重启稳定、写入可控、隐私/资源安心。总分只能称“Codex 产品实操候选分”；用户本人未认可前不得写“用户 10 分通过”。

- [ ] **Step 6: 发现缺陷时闭环重测**

每个缺陷：保存复现输入 → 写 RED 自动测试（真人主观项除外）→ 最小修复 → focused tests → 全量 gate → 从缺陷旅程开始并覆盖相邻旅程。不得用测试数量或实现复杂度为可见缺陷辩护。

- [ ] **Step 7: 最终范围/秘密/diff 审计**

Run: `git status --short --branch`

Run: `git diff --check`

Run: `git diff --stat origin/codex/jelly-inspiration-material-digest...HEAD`

Run: `rg -n 'MINIMAX_API_KEY=|Authorization:|Bearer |xsec_token|CBB0|sk-' Sources Tests docs || true`

Expected: 无秘密、无无关仓库改动、无测试 fixture 接入生产、无未解释生成物。

- [ ] **Step 8: 候选提交与 Codex review handoff**

Candidate commit:

```bash
git add docs/acceptance/2026-08-24-universal-material-digest-candidate.md
git commit -m "test(inspiration): 完成多格式提炼候选验收"
```

Grok 向 Codex 交付：开始/结束 commit、全部候选 commits、完整状态、RED/GREEN/gate 输出、最终 App 路径、10 条旅程证据、未验证真人项和所有已知限制。Grok 不自行推送、合并、发布或宣称用户验收通过。
