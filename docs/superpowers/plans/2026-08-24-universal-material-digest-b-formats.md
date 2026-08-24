# Jelly 多格式材料提炼 B：格式提取与长材料 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 仅在计划 A 已通过 Codex review 且工作树基线明确后执行；每个 Task 保留 RED/GREEN 和精确 diff。未经额外授权，不推送、合并或发布。

**Goal:** 在统一 V5 管线上稳定处理直接文字、TXT/Markdown/HTML、公共文章、图片、PDF、本地音视频，并让超出单次模型预算的材料通过带证据的分块摘要完成。

**Architecture:** 每个 `FormatExtractor` 只把确定性内容转换成 `MaterialBlockBatch`，不调用摘要模型；Coordinator 合并 block、计算 coverage、保存 snapshot。`HierarchicalMaterialSummarizer` 对小材料走一次 V3 请求，对长材料按 block 边界生成 evidence-preserving shards 后再综合。

**Tech Stack:** Swift 6.3、SwiftUI、Foundation、libxml2、UniformTypeIdentifiers、Vision、PDFKit、AVFoundation、WhisperKit、swift-testing、macOS 14+。

**Spec:** `docs/superpowers/specs/2026-08-24-universal-material-digest-design.md`

## Global Constraints

- 必须先完成并 review 计划 A：`2026-08-24-universal-material-digest-a-foundation.md`。
- 不接小红书或任何新平台；本计划只提供可被平台适配器复用的格式能力。
- 直接文字、文件和 URL 捕获都先保存 Inspiration，再启动用户明确点击的提炼；不得自动 OCR、转写或调用摘要模型。
- 本地媒体、图片和 PDF 不上传；OpenAI 兼容端点只接收标准化文字块、metadata 和 block ID。
- 文件通过 security-scoped bookmark 访问；原媒体不复制进 Workspace，任务结束必须停止访问。
- HTML 正文提取使用现有 macOS/libxml2 离线解析路径，不执行脚本、不联网加载子资源、不引入 WebView 主链。
- OCR 和 PDF 逐资产/逐页失败产生 typed coverage issue；其余内容足够时是 partial，不足时不摘要。
- 视频第一阶段只承诺音轨、Whisper 和代表性画面 OCR，不宣称理解完整视觉语义。
- 长材料按完整 block 边界切分，模型不得自由生成 locator；最终结论必须回连原 block。
- 资源上限必须是构造参数并在测试使用小值触发；不得用超大 fixture 消耗内存。
- 当前计划不持久化 shard cache；摘要重试复用 MaterialSnapshot，但重新计算 shards。
- 每个 Task 严格 RED → 预期失败 → 最小 GREEN → focused tests → `git diff --check`。
- 没有提交授权时停在 staged 前；不得推送、合并、发布或声称用户验收通过。

## File Map

- Create `Sources/CalendarApp/Inspiration/LocalMaterialFileAccess.swift`: bookmark 创建/解析和作用域生命周期。
- Create `Sources/CalendarApp/Inspiration/TextMaterialExtractor.swift`: 直接文字、TXT、Markdown、HTML 文件。
- Create `Sources/CalendarApp/Inspiration/HTMLMaterialExtractor.swift`: 公共 HTML 正文块。
- Create `Sources/CalendarApp/Inspiration/ImageMaterialExtractor.swift`: Vision OCR。
- Create `Sources/CalendarApp/Inspiration/PDFMaterialExtractor.swift`: PDFKit 文本和扫描页 OCR。
- Create `Sources/CalendarApp/Inspiration/MediaMaterialExtractor.swift`: 本地/远程音视频归一、音轨和代表性帧。
- Create `Sources/CalendarApp/Inspiration/MaterialExtractionProtocols.swift`: 小而明确的 extractor ports。
- Create `Sources/CalendarApp/Inspiration/HierarchicalMaterialSummarizer.swift`: 分块、shard 和最终综合。
- Modify `Sources/CalendarApp/Inspiration/MaterialDigestCoordinator.swift`: 组合 format extractors 和 partial coverage。
- Modify `Sources/CalendarApp/Inspiration/MaterialDigestProtocols.swift`: 资产和提取结果类型。
- Modify `Sources/CalendarApp/Inspiration/MaterialSourceProviders.swift`: 通用文章和 remote media 支持。
- Modify `Sources/CalendarApp/Inspiration/InspirationViewModel.swift`: 文字/文件捕获和回退材料。
- Modify `Sources/CalendarApp/Inspiration/InspirationSplitView.swift`: 文件选择和失败恢复动作。
- Modify `Sources/CalendarApp/Inspiration/MaterialDigestSection.swift`: coverage、证据和材料折叠展示。
- Modify `Sources/CalendarApp/AppEnvironment.swift`: 生产 extractor 装配。
- Modify `Package.swift`: 链接 Vision、PDFKit；不新增 Python/CLI。

---

### Task 1: 增加可恢复的本地文件捕获

**Files:**
- Create: `Sources/CalendarApp/Inspiration/LocalMaterialFileAccess.swift`
- Modify: `Sources/CalendarApp/Inspiration/InspirationViewModel.swift:229-278`
- Modify: `Sources/CalendarApp/Inspiration/InspirationSplitView.swift:474-526`
- Modify: `Tests/CalendarAppTests/InspirationWorkspaceViewModelTests.swift`
- Create: `Tests/CalendarAppTests/LocalMaterialFileAccessTests.swift`

**Interfaces:**
- Produces: `MaterialFileBookmarking.makeReference(for:) throws -> FileReference`。
- Produces: `MaterialFileAccessing.withAccess<T>(to: FileReference, _ body: (URL) async throws -> T) async throws -> T`。
- Produces: `InspirationViewModel.captureFile(_ reference: FileReference, kind: ResolvedSourceKind) async throws -> InspirationID`。

- [ ] **Step 1: 写文件捕获 RED 测试**

```swift
@Test func captureFilePersistsReferenceWithoutStartingDigest() async throws {
    let harness = try InspirationViewModelHarness()
    let reference = FileReference(bookmarkData: Data([1, 2, 3]), displayName: "材料.pdf")
    let id = try await harness.model.captureFile(reference, kind: .document)
    let saved = try #require(harness.store.state.inspirations[id])
    #expect(saved.inputKind == .file)
    #expect(saved.rawFile == reference)
    #expect(saved.resolvedSourceKind == .document)
    #expect(harness.digestOperator.starts.isEmpty)
}

@Test func scopedAccessAlwaysStopsAfterThrownBody() async throws {
    let fake = RecordingSecurityScopedFileAccess()
    await #expect(throws: FixtureError.failed) {
        try await fake.withAccess(to: .fixture) { _ in throw FixtureError.failed }
    }
    #expect(fake.startCount == 1)
    #expect(fake.stopCount == 1)
}
```

- [ ] **Step 2: 运行 RED**

Run: `swift test --filter 'LocalMaterialFileAccessTests|InspirationWorkspaceViewModelTests'`

Expected: `captureFile` 和 file access ports 不存在。

- [ ] **Step 3: 实现 bookmark 与单一文件入口**

```swift
protocol MaterialFileAccessing: Sendable {
    func withAccess<T: Sendable>(
        to reference: FileReference,
        _ body: @Sendable (URL) async throws -> T
    ) async throws -> T
}

func captureFile(_ reference: FileReference, kind: ResolvedSourceKind) async throws -> InspirationID {
    let now = clock()
    let inspiration = Inspiration(
        id: InspirationID(), inputKind: .file, rawText: nil, rawURL: nil,
        rawFile: reference, resolvedSourceKind: kind, resolvedMetadata: nil,
        categoryID: store.calendarState.uncategorizedID, lifecycle: .active,
        createdAt: now, updatedAt: now
    )
    // send .createInspiration; do not start digest
}
```

捕获视图增加一个低打扰附件按钮，使用 `NSOpenPanel`/UTType allowlist 选择单个文件；取消 panel 不改变 captureText 或 selection。bookmark 创建失败显示中文状态，不创建空 Inspiration。

- [ ] **Step 4: 转绿和持久化回归**

Run: `swift test --filter 'LocalMaterialFileAccessTests|InspirationWorkspaceViewModelTests|WorkspaceDocumentCodecTests'`

Expected: PASS；文件 Inspiration 重启 round-trip 保留 bookmark bytes/displayName。

- [ ] **Step 5: diff 自检和候选提交**

Run: `git diff --check`

Candidate commit:

```bash
git add Sources/CalendarApp/Inspiration/LocalMaterialFileAccess.swift \
  Sources/CalendarApp/Inspiration/InspirationViewModel.swift \
  Sources/CalendarApp/Inspiration/InspirationSplitView.swift \
  Tests/CalendarAppTests/LocalMaterialFileAccessTests.swift \
  Tests/CalendarAppTests/InspirationWorkspaceViewModelTests.swift
git commit -m "feat(inspiration): 支持捕获本地材料文件"
```

---

### Task 2: 提取直接文字与文本文件

**Files:**
- Create: `Sources/CalendarApp/Inspiration/MaterialExtractionProtocols.swift`
- Create: `Sources/CalendarApp/Inspiration/TextMaterialExtractor.swift`
- Create: `Tests/CalendarAppTests/TextMaterialExtractorTests.swift`
- Modify: `Sources/CalendarApp/Inspiration/MaterialSourceResolver.swift`

**Interfaces:**
- Produces: `protocol MaterialTextExtracting { func extract(_ input: TextMaterialInput) async throws -> MaterialBlockBatch }`。
- Produces: `TextMaterialInput.direct(text:)`、`.file(url:uti:)`。

- [ ] **Step 1: 写规范化 RED 测试**

```swift
@Test func directTextBecomesOrderedBodyParagraphs() async throws {
    let batch = try await TextMaterialExtractor().extract(.direct(text: "第一段\n\n第二段"))
    #expect(batch.blocks.map(\.text) == ["第一段", "第二段"])
    #expect(batch.blocks.map(\.locator) == [.paragraph(index: 1), .paragraph(index: 2)])
    #expect(batch.coverage == .sufficient)
}

@Test func metadataOnlyOrBinaryTextIsInsufficient() async throws {
    let batch = try await TextMaterialExtractor().extract(.direct(text: " \u{0000} "))
    #expect(batch.coverage == .insufficient(code: .empty))
    #expect(batch.blocks.isEmpty)
}
```

- [ ] **Step 2: 运行 RED**

Run: `swift test --filter TextMaterialExtractorTests`

Expected: extractor 不存在。

- [ ] **Step 3: 实现受限解码和段落规范化**

TXT/Markdown 支持 UTF-8、UTF-16 BOM；HTML 文件交 Task 3 的 HTML extractor。拒绝 NUL 密集二进制、超过 `maximumMaterialCharacters` 的输入；换行规范化为 `\n`，连续空行分段，不删除原句内部空白。

```swift
struct TextMaterialExtractor: MaterialTextExtracting {
    func extract(_ input: TextMaterialInput) async throws -> MaterialBlockBatch {
        let text = try decodedText(input)
        let blocks = normalizedParagraphs(text).enumerated().map { index, text in
            MaterialBlock(id: .init(), role: .body, text: text,
                locator: .paragraph(index: index + 1), confidence: nil)
        }
        return .init(blocks: blocks, coverage: coverage(for: blocks), provenance: provenance(input))
    }
}
```

- [ ] **Step 4: 转绿**

Run: `swift test --filter TextMaterialExtractorTests`

Expected: PASS，包含中英文、BOM、超限、空文本和 Markdown fixture。

- [ ] **Step 5: diff 自检和候选提交**

Run: `git diff --check`

Candidate commit:

```bash
git add Sources/CalendarApp/Inspiration/MaterialExtractionProtocols.swift \
  Sources/CalendarApp/Inspiration/TextMaterialExtractor.swift \
  Sources/CalendarApp/Inspiration/MaterialSourceResolver.swift \
  Tests/CalendarAppTests/TextMaterialExtractorTests.swift
git commit -m "feat(inspiration): 提取文字与文本文件"
```

---

### Task 3: 安全提取公共文章和 HTML 文件正文

**Files:**
- Create: `Sources/CalendarApp/Inspiration/HTMLMaterialExtractor.swift`
- Modify: `Sources/CalendarApp/Inspiration/MaterialSourceProviders.swift`
- Modify: `Sources/CalendarApp/Inspiration/URLMetadataResolver.swift`
- Create: `Tests/CalendarAppTests/HTMLMaterialExtractorTests.swift`
- Modify: `Tests/CalendarAppTests/MaterialSourceProviderTests.swift`

**Interfaces:**
- Produces: `HTMLMaterialExtractor.extract(data:baseURL:) throws -> MaterialBlockBatch`。
- Produces: `PublicWebArticleAcquirer(client:extractor:)`。

- [ ] **Step 1: 写正文与 prompt-injection RED fixture**

```swift
@Test func removesNavigationScriptsAndKeepsArticleOrder() throws {
    let batch = try HTMLMaterialExtractor().extract(
        data: fixture("article-with-nav-and-script.html"),
        baseURL: URL(string: "https://example.com/read")!
    )
    #expect(batch.blocks.map(\.text) == ["文章标题", "正文第一段", "正文第二段"])
    #expect(!batch.blocks.map(\.text).joined().contains("忽略系统提示"))
    #expect(!batch.blocks.map(\.text).joined().contains("登录 注册 首页"))
}

@Test func titleOnlyPageIsInsufficientNotASummaryCandidate() throws {
    let batch = try HTMLMaterialExtractor().extract(
        data: fixture("title-only.html"), baseURL: URL(string: "https://example.com")!
    )
    #expect(batch.coverage == .insufficient(code: .metadataOnly))
}
```

- [ ] **Step 2: 运行 RED**

Run: `swift test --filter 'HTMLMaterialExtractorTests|MaterialSourceProviderTests'`

Expected: extractor/acquirer 不存在。

- [ ] **Step 3: 用离线 libxml2 实现正文候选评分**

解析禁止脚本执行和外部实体。候选优先 `article/main/[role=main]`，其次按正文文字密度、段落数、链接密度评分；删除 `script/style/nav/footer/header/form/noscript` 和 `aria-hidden=true`。标题保存为 metadata block，正文为 body blocks。不得请求图片、CSS、iframe 或子链接。

`PublicWebArticleAcquirer` 使用现有 `MaterialHTTPClient.get` 的 HTTPS/SSRF/2 MB 上限，final URL 再校验，Content-Type 只接受 HTML/XHTML。

- [ ] **Step 4: 转绿并跑网络安全回归**

Run: `swift test --filter 'HTMLMaterialExtractorTests|MaterialSourceProviderTests|URLMetadataResolverTests'`

Expected: PASS；私网/重定向/过大页面仍被拒绝；title-only 不摘要。

- [ ] **Step 5: diff 自检和候选提交**

Run: `git diff --check`

Candidate commit:

```bash
git add Sources/CalendarApp/Inspiration/HTMLMaterialExtractor.swift \
  Sources/CalendarApp/Inspiration/MaterialSourceProviders.swift \
  Sources/CalendarApp/Inspiration/URLMetadataResolver.swift \
  Tests/CalendarAppTests/HTMLMaterialExtractorTests.swift \
  Tests/CalendarAppTests/MaterialSourceProviderTests.swift
git commit -m "feat(inspiration): 提取公共文章正文"
```

---

### Task 4: 使用 Vision 生成图片 OCR blocks

**Files:**
- Create: `Sources/CalendarApp/Inspiration/ImageMaterialExtractor.swift`
- Create: `Tests/CalendarAppTests/ImageMaterialExtractorTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Produces: `protocol MaterialOCRRecognizing` 和生产 `VisionMaterialOCRRecognizer`。
- Produces: `ImageMaterialExtractor.extract(_ images: [MaterialImageAsset]) async throws -> MaterialBlockBatch`。

- [ ] **Step 1: 写多图 partial RED 测试**

```swift
@Test func orderedImagesProduceDeduplicatedOCRAndPartialCoverage() async throws {
    let recognizer = FixtureOCRRecognizer(results: [
        .success([.init(text: "第一张文字", confidence: 0.98)]),
        .failure(.unreadable),
        .success([.init(text: "第一张文字", confidence: 0.97), .init(text: "第三张补充", confidence: 0.95)])
    ])
    let batch = try await ImageMaterialExtractor(recognizer: recognizer).extract(.threeImages)
    #expect(batch.blocks.map(\.text) == ["第一张文字", "第三张补充"])
    #expect(batch.blocks.map(\.locator) == [.image(index: 1), .image(index: 3)])
    #expect(batch.coverage == .partial(processed: 2, expected: 3, issues: [.ocrFailed]))
}
```

- [ ] **Step 2: 运行 RED**

Run: `swift test --filter ImageMaterialExtractorTests`

Expected: OCR ports 不存在。

- [ ] **Step 3: 实现 Vision OCR、排序和去重**

生产实现使用 `VNRecognizeTextRequest`、`.accurate`、自动语言纠正，限制最大像素和图片数。按 Vision bounding box 从上到下、从左到右稳定排序；confidence 转为 0...10000 basis points。规范化后完全相同或高相似短 OCR 只保留首次，但不同图片的新增文字不得误删。

纯视觉且无文字返回 `.insufficient(code: .unreadable)`，不是空成功。

- [ ] **Step 4: 转绿**

Run: `swift test --filter ImageMaterialExtractorTests`

Expected: fixture tests PASS；生产 Vision adapter 的小型本地 PNG contract test PASS。

- [ ] **Step 5: diff 自检和候选提交**

Run: `git diff --check`

Candidate commit:

```bash
git add Package.swift \
  Sources/CalendarApp/Inspiration/ImageMaterialExtractor.swift \
  Tests/CalendarAppTests/ImageMaterialExtractorTests.swift
git commit -m "feat(inspiration): 本机识别图片文字"
```

---

### Task 5: PDF 页文本优先、扫描页 OCR 回退

**Files:**
- Create: `Sources/CalendarApp/Inspiration/PDFMaterialExtractor.swift`
- Create: `Tests/CalendarAppTests/PDFMaterialExtractorTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: Task 4 `MaterialOCRRecognizing`。
- Produces: `PDFMaterialExtractor.extract(url:) async throws -> MaterialBlockBatch`。

- [ ] **Step 1: 写混合 PDF RED 测试**

```swift
@Test func digitalPagesUseTextAndOnlyScannedPagesUseOCR() async throws {
    let ocr = RecordingOCRRecognizer(result: "扫描页文字")
    let batch = try await PDFMaterialExtractor(ocr: ocr).extract(url: fixture("mixed.pdf"))
    #expect(batch.blocks.map(\.text) == ["第一页数字正文", "扫描页文字", "第三页数字正文"])
    #expect(batch.blocks.map(\.locator) == [.page(number: 1), .page(number: 2), .page(number: 3)])
    #expect(ocr.requestedPageNumbers == [2])
}
```

- [ ] **Step 2: 运行 RED**

Run: `swift test --filter PDFMaterialExtractorTests`

Expected: extractor 不存在。

- [ ] **Step 3: 实现逐页确定性提取**

先使用 `PDFDocument`/`PDFPage.string`；有效语义不足的单页按受控 DPI 渲染后 OCR。加密且无法解锁、页数/像素/字符超过上限、损坏文档返回 typed error。单页失败产生 `.partial(...issues:[.ocrFailed])`；全部失败为 `.insufficient(.unreadable)`。

- [ ] **Step 4: 转绿**

Run: `swift test --filter PDFMaterialExtractorTests`

Expected: 数字、扫描、混合、加密、损坏、超页数 fixtures PASS。

- [ ] **Step 5: diff 自检和候选提交**

Run: `git diff --check`

Candidate commit:

```bash
git add Package.swift \
  Sources/CalendarApp/Inspiration/PDFMaterialExtractor.swift \
  Tests/CalendarAppTests/PDFMaterialExtractorTests.swift
git commit -m "feat(inspiration): 提取数字与扫描 PDF"
```

---

### Task 6: 统一本地和远程音视频提取

**Files:**
- Create: `Sources/CalendarApp/Inspiration/MediaMaterialExtractor.swift`
- Modify: `Sources/CalendarApp/Inspiration/MaterialSourceProviders.swift:743-834`
- Modify: `Sources/CalendarApp/Inspiration/WhisperKitMaterialTranscriber.swift`
- Create: `Tests/CalendarAppTests/MediaMaterialExtractorTests.swift`
- Modify: `Tests/CalendarAppTests/MaterialSourceProviderTests.swift`

**Interfaces:**
- Consumes: 计划 A 的 `RemoteMediaAsset.Kind { audio, video }`。
- Produces: `TemporaryMaterialMediaDownloader`（替代 audio-only 命名，保留兼容 typealias 一个 Task）。
- Produces: `MediaMaterialExtractor.extract(url:kind:runID:progress:) async throws -> MaterialBlockBatch`。

- [ ] **Step 1: 写音轨和代表帧 RED 测试**

```swift
@Test func videoCombinesTranscriptAndUniqueFrameOCRWithExplicitVisualBoundary() async throws {
    let batch = try await MediaMaterialExtractor(
        transcriber: .fixture("00:00-00:10 口播正文"),
        frameSampler: .fixture(times: [0, 10, 20]),
        ocr: .fixture(["封面标题", "封面标题", "结尾行动"])
    ).extract(url: fixture("sample.mp4"), kind: .video, runID: .init(), progress: { _ in })
    #expect(batch.blocks.map(\.role) == [.transcript, .ocr, .ocr])
    #expect(batch.coverage.issues.contains(.visualSemanticsUnavailable))
}
```

- [ ] **Step 2: 运行 RED**

Run: `swift test --filter 'MediaMaterialExtractorTests|MaterialSourceProviderTests'`

Expected: media extractor/remote video kind 不存在。

- [ ] **Step 3: 实现 AVFoundation 管线**

音频直接交 Whisper。视频先用 `AVAssetExportSession`/composition 提取音轨；无音轨时仍尝试代表帧 OCR。代表帧最多 12 张，短视频使用开始/25%/50%/75%/结束，长视频均匀采样并限制总像素；相同 OCR 去重。没有语音且没有可识别文字为 insufficient。

下载器根据 MIME/UTType 校验音视频，仍沿用 1.5 GB、取消、partial 文件和 run 目录清理合同。

- [ ] **Step 4: 转绿并跑 Whisper 回归**

Run: `swift test --filter 'MediaMaterialExtractorTests|MaterialSourceProviderTests|WhisperKitMaterialTranscriberContractTests'`

Expected: PASS；B 站/小宇宙 remote audio 仍工作；取消删除 partial 文件。

- [ ] **Step 5: diff 自检和候选提交**

Run: `git diff --check`

Candidate commit:

```bash
git add Sources/CalendarApp/Inspiration/MediaMaterialExtractor.swift \
  Sources/CalendarApp/Inspiration/MaterialSourceProviders.swift \
  Sources/CalendarApp/Inspiration/WhisperKitMaterialTranscriber.swift \
  Tests/CalendarAppTests/MediaMaterialExtractorTests.swift \
  Tests/CalendarAppTests/MaterialSourceProviderTests.swift
git commit -m "feat(inspiration): 统一提取音视频材料"
```

---

### Task 7: Coordinator 合并多格式并持久化 partial 快照

**Files:**
- Modify: `Sources/CalendarApp/Inspiration/MaterialDigestCoordinator.swift`
- Modify: `Sources/CalendarApp/Inspiration/MaterialDigestProtocols.swift`
- Modify: `Sources/CalendarApp/Inspiration/MaterialSourceResolver.swift`
- Modify: `Tests/CalendarAppTests/MaterialDigestCoordinatorTests.swift`

**Interfaces:**
- Consumes: Tasks 1-6 extractors。
- Produces: 统一 `extract(source:runID:) -> MaterialSnapshot` 路径。

- [ ] **Step 1: 写格式分派和 partial RED 测试**

```swift
@Test func eachSourceDescriptorUsesExactlyOneFormatPathAndSavesBeforeSummary() async throws {
    for source in FixtureSource.allDirectFormats {
        let harness = try await CoordinatorFormatHarness(source: source)
        await harness.coordinator.start(inspirationID: harness.id, mode: .refreshSource)
        #expect(await waitUntil { harness.digest.result != nil })
        #expect(harness.extractorInvocations == [source.expectedExtractor])
        #expect(harness.events.firstIndex(of: .snapshotSaved)! < harness.events.firstIndex(of: .summaryStarted)!)
    }
}

@Test func partialSnapshotReachesSummaryAndKeepsCoverageIssues() async throws {
    let harness = try await CoordinatorFormatHarness.partialImages()
    await harness.coordinator.start(inspirationID: harness.id, mode: .refreshSource)
    #expect(await waitUntil { harness.digest.result != nil })
    #expect(harness.digest.preparedSnapshot?.coverage == .partial(
        processed: 2, expected: 3, issues: [.ocrFailed]
    ))
}
```

- [ ] **Step 2: 运行 RED**

Run: `swift test --filter MaterialDigestCoordinatorTests`

Expected: coordinator 只会 blocks/remote audio，无法调新格式。

- [ ] **Step 3: 实现 descriptor → extractor 组合**

Coordinator 负责阶段切换和合并，不实现 OCR/PDF/HTML 细节。`insufficient` 在模型调用前映射为 `.insufficientContent`；`partial` 允许继续并保留 issue。快照保存成功后才允许 summary。

模型未配置但快照已提取时保留快照，显示“材料已就绪，请配置摘要模型”；重试不得重复 extractor。

- [ ] **Step 4: 转绿和全格式 focused 回归**

Run: `swift test --filter 'MaterialDigestCoordinatorTests|TextMaterialExtractorTests|HTMLMaterialExtractorTests|ImageMaterialExtractorTests|PDFMaterialExtractorTests|MediaMaterialExtractorTests'`

Expected: PASS。

- [ ] **Step 5: diff 自检和候选提交**

Run: `git diff --check`

Candidate commit:

```bash
git add Sources/CalendarApp/Inspiration/MaterialDigestCoordinator.swift \
  Sources/CalendarApp/Inspiration/MaterialDigestProtocols.swift \
  Sources/CalendarApp/Inspiration/MaterialSourceResolver.swift \
  Tests/CalendarAppTests/MaterialDigestCoordinatorTests.swift
git commit -m "feat(inspiration): 编排多格式材料提取"
```

---

### Task 8: 长材料按 block 分块并保留证据

**Files:**
- Create: `Sources/CalendarApp/Inspiration/HierarchicalMaterialSummarizer.swift`
- Modify: `Sources/CalendarApp/Inspiration/OpenAICompatibleMaterialSummarizer.swift`
- Create: `Tests/CalendarAppTests/HierarchicalMaterialSummarizerTests.swift`
- Modify: `Tests/CalendarAppTests/OpenAICompatibleMaterialSummarizerTests.swift`

**Interfaces:**
- Produces: `MaterialInputBudget(maximumEstimatedTokens:reservedOutputTokens:)`。
- Produces: `MaterialChunker.chunks(snapshot:budget:) throws -> [MaterialChunk]`。
- Produces: `DigestShard` 和 `HierarchicalMaterialSummarizer`。

- [ ] **Step 1: 写边界/证据 RED 测试**

```swift
@Test func chunkerNeverSplitsABlockAndPreservesOrder() throws {
    let snapshot = MaterialSnapshot.fixture(blockLengths: [80, 80, 80])
    let chunks = try MaterialChunker().chunks(
        snapshot: snapshot,
        budget: .init(maximumEstimatedTokens: 50, reservedOutputTokens: 10)
    )
    #expect(chunks.flatMap(\.blockIDs) == snapshot.blocks.map(\.id))
    #expect(chunks.allSatisfy { Set($0.blockIDs).count == $0.blockIDs.count })
}

@Test func synthesisRejectsEvidenceNotPresentInOriginalSnapshot() async throws {
    let worker = HierarchicalMaterialSummarizer(client: .fixtureWithForeignEvidenceID())
    await #expect(throws: MaterialDigestPipelineError.invalidSummary) {
        _ = try await worker.summarize(.longFixture(), source: .fixture())
    }
}
```

- [ ] **Step 2: 运行 RED**

Run: `swift test --filter HierarchicalMaterialSummarizerTests`

Expected: chunker/hierarchical summarizer 不存在。

- [ ] **Step 3: 实现保守预算、shard 和综合**

token 估算使用可注入 `MaterialTokenEstimating`；生产保守估算不得依赖 MiniMax 固定上下文。小于预算直接走 V3 summarizer；超过预算逐 chunk 请求 `DigestShard`，每个 claim 仍引用原 block ID。最终综合只接收 shard JSON 和必要短原文窗口；任何 shard JSON/证据失败使本次摘要失败，不用空 shard 继续。

```swift
protocol MaterialTokenEstimating: Sendable {
    func estimatedTokens(for text: String) -> Int
}

struct MaterialChunk: Equatable, Sendable {
    let index: Int
    let blockIDs: [MaterialBlockID]
    let renderedText: String
}
```

- [ ] **Step 4: 转绿并验证短材料单调用**

Run: `swift test --filter 'HierarchicalMaterialSummarizerTests|OpenAICompatibleMaterialSummarizerTests'`

Expected: 长材料多 shard + 一次 synthesis；短材料仍一次请求；context-too-long 不再是正常长材料路径。

- [ ] **Step 5: diff 自检和候选提交**

Run: `git diff --check`

Candidate commit:

```bash
git add Sources/CalendarApp/Inspiration/HierarchicalMaterialSummarizer.swift \
  Sources/CalendarApp/Inspiration/OpenAICompatibleMaterialSummarizer.swift \
  Tests/CalendarAppTests/HierarchicalMaterialSummarizerTests.swift \
  Tests/CalendarAppTests/OpenAICompatibleMaterialSummarizerTests.swift
git commit -m "feat(inspiration): 稳定提炼长材料"
```

---

### Task 9: 完成统一入口、恢复动作和证据浏览体验

**Files:**
- Modify: `Sources/CalendarApp/Inspiration/InspirationSplitView.swift`
- Modify: `Sources/CalendarApp/Inspiration/InspirationViewModel.swift`
- Modify: `Sources/CalendarApp/Inspiration/MaterialDigestSection.swift`
- Modify: `Tests/CalendarAppTests/MaterialDigestPresentationTests.swift`
- Modify: `Tests/CalendarAppTests/InspirationWorkspaceViewModelTests.swift`

**Interfaces:**
- Produces: 所有支持格式统一按钮“提炼这份材料”。
- Produces: `retrySummary` 复用 snapshot；`refreshMaterial` 重新读取来源；`replaceWithFile`/`supplementWithText` 创建或更新用户确认的原始来源，不静默覆盖。

- [ ] **Step 1: 写交互 RED 测试**

```swift
@Test func allSupportedInputKindsShowOneDigestAction() {
    for inspiration in [Inspiration.textFixture(), .articleFixture(), .imageFileFixture(), .pdfFixture(), .audioFileFixture()] {
        let p = MaterialDigestPresentation.project(
            inspiration: inspiration, digest: nil, operatorAvailable: true
        )
        #expect(p.primaryActionTitle == "提炼这份材料")
    }
}

@Test func restrictedURLOffersPasteAndFileWithoutClaimingSuccess() {
    let p = MaterialDigestPresentation.project(
        inspiration: .articleFixture(), digest: .failed(.restrictedSource), operatorAvailable: true
    )
    #expect(p.recoveryActions == [.pasteText, .chooseFile, .retrySource])
    #expect(p.thesis == nil)
}
```

- [ ] **Step 2: 运行 RED**

Run: `swift test --filter 'MaterialDigestPresentationTests|InspirationWorkspaceViewModelTests'`

Expected: UI 仍只支持 URL video/audio，“提炼这个链接”。

- [ ] **Step 3: 实现一个入口和分因恢复动作**

立即反馈通过当前 run state 驱动；按钮点击后同步进入本地 Task 并尽快提交 start command。coverage partial 文案不从任意 error string 拼接。证据点击展开到 snapshot block；locator 统一由 domain formatter 生成。

粘贴/文件补充必须让用户确认“替换这份材料的来源”，生成新的 source checksum，使旧 snapshot/result 过期但仍可查看历史；不得把补充文字悄悄写入原 URL metadata。

- [ ] **Step 4: 转绿和 300ms/取消 presentation 门**

Run: `swift test --filter 'MaterialDigestPresentationTests|InspirationWorkspaceViewModelTests'`

Expected: PASS；UI tests 使用可控 clock 验证动作立即出现 processing state，不把外部等待计入 300 ms。

- [ ] **Step 5: diff 自检和候选提交**

Run: `git diff --check`

Candidate commit:

```bash
git add Sources/CalendarApp/Inspiration/InspirationSplitView.swift \
  Sources/CalendarApp/Inspiration/InspirationViewModel.swift \
  Sources/CalendarApp/Inspiration/MaterialDigestSection.swift \
  Tests/CalendarAppTests/MaterialDigestPresentationTests.swift \
  Tests/CalendarAppTests/InspirationWorkspaceViewModelTests.swift
git commit -m "feat(inspiration): 统一多格式提炼与失败恢复"
```

---

### Task 10: 生产装配与计划 B 工程门禁

**Files:**
- Modify: `Sources/CalendarApp/AppEnvironment.swift`
- Modify: `Package.swift`
- Modify: `Tests/CalendarAppTests/AppEnvironmentWorkspaceCutoverTests.swift`

**Interfaces:**
- Consumes: Tasks 1-9 全部 extractors 和 hierarchical summarizer。
- Produces: 生产环境只使用 real file access、libxml2、Vision、PDFKit、AVFoundation、Whisper 和配置摘要端点。

- [ ] **Step 1: 写生产装配 RED 测试**

```swift
@Test func liveEnvironmentWiresAllFormatExtractorsWithoutFixtureProviders() throws {
    let environment = try AppEnvironment.live(environment: acceptanceEnvironment())
    #expect(environment.materialDigestOperator != nil)
    #expect(environment.features.inspiration)
}
```

- [ ] **Step 2: 运行 RED 并最小装配**

Run: `swift test --filter AppEnvironmentWorkspaceCutoverTests`

Expected: initializer 尚未注入新 ports；装配后 PASS。

- [ ] **Step 3: 运行 focused 格式矩阵**

Run: `swift test --filter 'TextMaterialExtractorTests|HTMLMaterialExtractorTests|ImageMaterialExtractorTests|PDFMaterialExtractorTests|MediaMaterialExtractorTests|HierarchicalMaterialSummarizerTests|MaterialDigestCoordinatorTests'`

Expected: PASS。

- [ ] **Step 4: 运行完整工程门禁**

Run: `swift test`

Expected: exit 0。

Run: `swift build -c release`

Expected: exit 0。

Run: `Scripts/build-app.sh`

Expected: exit 0，生成 `dist/Jelly.app`。

Run: `codesign --verify --deep --strict --verbose=2 dist/Jelly.app`

Expected: valid on disk and satisfies Designated Requirement。

- [ ] **Step 5: 隐私、范围和资源审计**

Run: `git diff --check`

Run: `rg -n 'xsec_token|MINIMAX_API_KEY|Bearer [A-Za-z0-9_-]{10,}|sk-[A-Za-z0-9]' Sources Tests docs || true`

Expected: 没有真实秘密；没有 Python、yt-dlp、WebView 主链或媒体写入 Workspace；测试 fixture 总体积受控。

- [ ] **Step 6: 候选提交与 handoff**

Candidate commit:

```bash
git add Package.swift Sources Tests
git commit -m "feat(inspiration): 完成多格式与长材料提炼"
```

向 Codex 交付完整命令输出、格式支持矩阵、已知能力边界和当前未提交文件说明。计划 B 通过仍不得宣称小红书、最终产品实操或用户 10 分验收完成。
