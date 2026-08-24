# Jelly 灵感材料提炼设计

日期：2026-08-22
状态：设计已由用户确认，可进入实现
目标分支：`codex/jelly-inspiration-material-digest`

## 1. 结论

Jelly 把 B 站视频和小宇宙单集接入现有“灵感”模块，不新增一级入口，也不嵌入外部转录工具。

用户旅程遵循三句话：

1. **捕获自动**：粘贴链接后立即保存原始 URL，只做轻量标题解析和来源分类。
2. **提炼主动**：用户在灵感详情中点击“提炼这个链接”后，才开始字幕、音频、识别和摘要处理。
3. **写入再次确认**：提炼结果先供审阅；用户确认后，才把原始链接和摘要结构写入笔记。

第一期只支持 B 站视频页和小宇宙单集页。文章全文、文件、自动提炼、聊天问材料、知识图谱、全文翻译、说话人分离均不在本期范围。

## 2. 用户视角

### 2.1 捕获

用户把链接粘贴进灵感捕获框：

- 原始链接立即落盘，界面明确反馈“已保存原始链接”。
- 捕获操作不等待网络、字幕、音频、Whisper 或模型。
- 后台轻量识别来源并获取标题；轻量解析失败也不影响原始链接。
- B 站视频页显示“B 站视频”，小宇宙单集页显示“小宇宙单集”。
- 小宇宙节目首页不猜具体单集，B 站专栏或空间页不冒充视频。

### 2.2 主动提炼

支持的链接在详情“来源”区域下显示一块低打扰的提炼区：

- 初始文案说明“尚未提炼”，主操作为“提炼这个链接”。
- 不在捕获后弹确认框，不自动消耗模型、网络和本机计算资源。
- 未配置摘要模型时，入口仍可见；点击后明确引导配置，不生成假摘要。
- 用户开始提炼后可以离开当前页面，稍后回来查看。
- 处理阶段用人话显示：视频统一显示“正在准备视频材料”，音频显示“正在获取音频”；视频没有可公开读取的字幕而转本机识别时明确说明原因。模型下载只显示可信的下载中状态，不把上游文件数进度冒充字节百分比。
- 处理中提供取消；失败提供具体原因和重试；旧的成功结果在重试期间继续可读。
- 只有确实需要本机识别且模型尚未安装时，才显示首次模型下载说明（约 626 MB）并让用户确认“下载并继续”；能公开读取字幕的材料不触发模型下载。

以后可以增加“支持的链接自动提炼”设置，但默认关闭，且不进入第一期。

### 2.3 审阅并写入笔记

提炼成功后，详情展示：

- 一句话核心论点；
- 3～7 条主要观点；
- 带时间戳的章节；
- 可选引用；
- 被识别为广告、片头片尾或赞助口播的内容；
- 可折叠的完整文稿。

用户点击“写入笔记”后：

1. 笔记第一块保留可点击的原始链接；
2. 后续追加核心论点、主要观点、章节和必要引用；
3. 完整文稿仍留在 Digest 中，不默认灌入笔记；
4. 重复点击打开同一篇已转换笔记，不创建第二篇。
5. 如果文件系统只能确认“可能已经写入”而不能确认原子提交完成，界面不得静默或显示成功；原始灵感继续留在待处理区，主操作改为“继续确认写入”，并只用该次事务令牌确认。确认提交后才移动到“已成笔记”，确认未提交后允许重新写入。

摘要是可编辑草稿，不覆盖原始材料，也不自动升级为任务、日程或知识。任何不确定、未提交、外部数据变化或写入受阻都必须给出可行动的中文状态，不得吞掉结果让按钮看起来没有生效。

## 3. 领域边界

### 3.1 原始灵感不变

`Inspiration` 继续只保存用户原始输入、轻量元数据、来源类型、分类和生命周期。字幕、文稿、摘要和模型信息不得写入 `rawText`、`rawURL` 或 `resolvedMetadata`。

### 3.2 新增 MaterialDigest

第一期每条灵感只有一个当前 Digest，存储形态建议为：

```swift
public struct MaterialDigest: Identifiable, Codable, Equatable, Sendable {
    public let id: MaterialDigestID
    public let inspirationID: InspirationID
    public let sourceChecksum: String
    public var currentRun: MaterialDigestRun?
    public var result: MaterialDigestResult?
    public var lastFailure: MaterialDigestFailure?
    public var createdAt: Date
    public var updatedAt: Date
}
```

关键点：

- `sourceChecksum` 使用 `WorkspaceChecksum.inspirationSourceChecksum`，绑定创建 Digest 时的原始来源。
- `currentRun` 与最后一次成功 `result` 分开，重试不会先抹掉旧结果。
- 集合以 `InspirationID` 为 key，Validator 同时校验 key、`inspirationID` 与引用关系。
- 永久删除灵感时原子删除 Digest；归档、恢复和转笔记保留 Digest。

摘要结果使用明确字段，不存自由散文：

```swift
public struct MaterialDigestResult: Codable, Equatable, Sendable {
    public var transcript: TimestampedTranscript
    public var summary: InspirationSummary
    public var provenance: DigestProvenance
    public var completedAt: Date
}

public struct InspirationSummary: Codable, Equatable, Sendable {
    public var thesis: String
    public var takeaways: [String]
    public var chapters: [DigestChapter]
    public var quotes: [DigestQuote]
    public var dropped: [String]
}
```

Validator 至少保证：核心论点非空、主要观点为 3～7 条、章节时间戳合法且有序、成功结果带 provenance、Digest 引用存在的灵感、成功结果的 checksum 与当前灵感一致。

## 4. 运行状态与并发

每次提炼生成新的 `runID`。领域层保存当前运行阶段：

```swift
public enum MaterialDigestStage: String, Codable, Equatable, Sendable {
    case fetchingSource
    case awaitingModelDownloadConsent
    case downloadingModel
    case transcribing
    case summarizing
}
```

工作区命令由 Reducer 处理，视图不得直接改 Digest 集合：

- `startMaterialDigest`
- `advanceMaterialDigestStage`
- `completeMaterialDigest`
- `failMaterialDigest`
- `cancelMaterialDigest`
- `markInterruptedMaterialDigest`

每条命令携带 `inspirationID`、`runID` 和预期 `sourceChecksum`。Reducer 只有在三者都与当前运行匹配时才接受结果，否则返回明确的 no-change 原因。由此阻止：

- 取消后迟到的完成结果写回；
- 重试后旧运行覆盖新运行；
- 来源变化后旧摘要写回；
- 同一灵感的并发提炼相互串台。

App 退出不会在后台伪装继续运行。下次启动时，遗留的获取、下载、识别或摘要阶段统一转换为“上次处理被中断”，保留已有成功结果并允许重试；等待用户确认下载模型的阶段保持可继续，不冒充后台任务。

## 5. 提炼管线

App 层通过小而明确的接口组合管线，不把网络、字幕或模型逻辑塞进 View：

```swift
protocol MaterialSourceClassifying {
    func classify(_ url: URL) -> ResolvedSourceKind?
}

protocol MaterialTextProviding {
    func text(for source: MaterialSource, progress: ...) async throws -> TimestampedTranscript
}

protocol MaterialSummarizing {
    func summarize(_ transcript: TimestampedTranscript, source: MaterialSource) async throws -> SummarizationOutput
}
```

`MaterialDigestCoordinator` 负责把外部工作和领域命令串起来：

```text
用户点击提炼
  → startMaterialDigest
  → 获取字幕或音频
  → 必要时本机识别
  → 一次模型调用生成结构化 JSON
  → 本地校验 JSON
  → completeMaterialDigest
```

Coordinator 只提交候选结果；Reducer 和 Validator 决定候选是否仍可写入。

### 5.1 B 站

- 只认 `bilibili.com/video/...` 和 `b23.tv` 视频分享链接。
- 优先获取中文人工字幕，其次中文自动字幕。
- 字幕覆盖率或有效文本不足时再取音频并本机识别。
- 第一版只处理落地页对应分 P。
- 不使用用户 Cookie；受限视频给出明确失败，不绕过权限。

### 5.2 小宇宙

- 只认 `xiaoyuzhoufm.com/episode/...` 单集页。
- 从页面 `og:audio`、JSON-LD 或对应单集 RSS 获取音频地址。
- 节目首页不猜最新一集。
- 摘要提示要求识别并列出广告、片头片尾和赞助口播，但 `dropped` 只是可审阅判断，不删除原文稿。

### 5.3 识别与摘要

- Apple silicon、macOS 14+；识别固定使用 Argmax OSS Swift Package `1.0.0` 的 `WhisperKit` 产品，不嵌 Python、Homebrew CLI 或外部常驻服务。
- 第一版固定模型 `large-v3-v20240930_626MB`（Large v3 Turbo compressed）；模型放在 App 数据目录的独立 `Models/WhisperKit` 目录，可复用、可显式删除，不打进 `.app`。
- 首次下载必须有体积说明、可信的进行中状态、取消和失败重试；上游不能提供真实字节进度时不得展示百分比。模型下载不是提炼成功状态，也不得阻塞可公开读取的字幕路径。
- 音视频不上传到 Jelly 自有服务器。
- 摘要使用用户配置的 OpenAI 兼容端点和模型。
- 凭据只进入系统钥匙串或既有安全设置，不写进 Workspace、日志、表单持久化或导出文件。
- 使用 `JELLY_ACCEPTANCE_DATA_DIRECTORY` 启动隔离验收时，Keychain 服务名和 endpoint/model 偏好域必须由该目录派生；不同验收目录互不共享，也不得读取或覆盖正式 Jelly 的配置。隔离命名空间创建失败时启动失败，不回退到正式配置。
- 模型必须一次返回结构化 JSON；解析或业务校验失败即失败，不用占位文案冒充摘要。
- OpenAI 兼容请求给模型最多 8192 个 completion token，避免推理模型在长视频上先耗尽默认输出预算、把最终 JSON 截断；响应仍受 4 MB 硬上限约束。
- 已获取的来源标题可以作为摘要模型的不可信专有名词拼写上下文；标题不进入 Whisper，不作为事实或引用证据，完整文稿不做摘要后改写。
- provenance 保存模型标识、生成时间、包含实际标题上下文的输入指纹和摘要合同版本，不保存密钥。

## 6. 持久化与迁移

`WorkspaceState` 新增 `materialDigests: [InspirationID: MaterialDigest]`。

`WorkspaceDocument.currentSchemaVersion` 保持为 4，把 Digest 作为可选的派生扩展字段：

- 新版 V4 显式编码 Digest 集合；旧 V4 文档缺少该字段时解码为空集合；
- 原有日历、笔记、灵感、关系、revision 和墓碑保持不变；
- 备份、恢复和内容快照显式包含 Digest；
- 新文档仍可由旧版 Jelly 打开，保证回滚时原始链接和用户笔记可读；
- 边界：旧版 Jelly 保存新文档时会忽略并丢弃派生 Digest，但不会丢原始链接和笔记。正式升级前必须保留备份，不能把这一点描述成无损双向兼容；
- “写入笔记”后的 V4 文档必须能被当前版本完整重开；Digest 写入回执只能声明该笔记中真实存在的摘要块，旧回执可以保留旧结果指纹，以便新摘要写入时只替换上一版摘要、不碰用户块；
- 校验失败的文档不得覆盖当前可读数据。

## 7. 笔记转换

现有 `convertInspirationToNote` 保持“同一灵感只对应一篇笔记”的合同，但构造候选 Note 时读取当前有效 Digest：

- 没有成功 Digest：保持现有行为，仅写原始链接；
- 有成功且 checksum 匹配的 Digest：写入来源链接 + 摘要结构；
- Digest 处理中、失败、被取消或过期：不写入半成品；
- 用户点击“写入笔记”是唯一写入动作，提炼成功本身不自动建笔记。

建议 Block 顺序：

1. `.link`：原始来源；
2. `.heading2`：核心观点；
3. `.paragraph`：thesis；
4. `.heading2`：主要观点；
5. 多个 `.bullet`：takeaways；
6. 有章节时写 `.heading2` + 章节条目；
7. 有引用时写 `.heading2` + quote。

完整文稿不进入 Note，避免一次转换制造过重正文。

## 8. 失败与恢复

失败只修改 Digest 运行状态，绝不修改原始 URL、元数据、已有成功结果或既有笔记。

错误分为可操作类别：

- 不支持的来源或不是单集/视频页；
- 来源受限、字幕不可用或音频无法获取；
- 用户取消；
- 本机识别失败或模型资源不可用；
- 未配置摘要模型或凭据；
- 摘要请求失败；
- JSON 无法解析或不满足摘要合同；
- 来源已变化或运行已过期；
- App 上次退出导致处理中断。

界面显示对用户有意义的原因和下一步，不暴露原始堆栈、密钥、完整模型响应或临时音频路径。

临时字幕和音频采用任务级临时目录；成功、失败、取消后都清理。任何清理失败不得误报为提炼失败，但需要安全记录不含敏感内容的诊断。

## 9. 实现切片

### Slice A：来源分类

重新实现并验证 CC 候选中的域名分类思路：

- 分类在网络请求前完成；
- 元数据解析成功时不再一律标为 article；
- B 站/小宇宙 HTML 解析失败时仍保留可由域名确定的 kind；
- 修正 CC 新增测试目前无法编译的问题；
- 不带入同一 `main` 工作区里的日历和周视图改动。

### Slice B：Digest 合同和 V4 可选扩展

新增模型、Reducer 命令、Validator、删除/恢复/快照语义和显式迁移。用 fixture 结果跑通完整状态机，不接真实模型。

### Slice C：详情交互和 fixture 纵切

实现手动提炼入口、真实状态文案、取消/重试、审阅结果和写入笔记。用可控 fixture 跑通完整用户流程，fixture 不进入发布默认路径。

### Slice D：真实材料获取与本机识别

接 B 站中文字幕优先、小宇宙音频解析和本机识别；覆盖取消、临时文件清理和权限失败。

### Slice E：真实摘要与最终实操

接用户 OpenAI 兼容配置、结构化 JSON 摘要、provenance、最终打包产物和真实来源实操。

每个切片完成后自动继续下一个，只有遇到需要扩大范围、外部依赖不可用或必须由用户决定的产品冲突才暂停。

## 10. 验证与完成口径

### 10.1 工程验证

至少覆盖：

- 来源分类表格和相似域名拒绝；
- HTML 成功/失败时的 kind 与 raw URL 保留；
- Digest 状态转换、Validator 和 revision；
- runID、checksum、取消和重试的迟到结果拒绝；
- 重试保留上次成功结果；
- 永久删除、归档、恢复和内容快照；
- 旧 V4 缺字段兼容、新 V4 round-trip，以及旧 V4 reader 对原始链接和笔记的回读；
- 带 `noteWrite` 回执的写入后 V4 round-trip，以及回执指向不存在块时的拒绝；
- 失败不改 Inspiration 和 Note；
- 笔记 Block 类型、顺序和重复转换；
- App 重启后的中断恢复；
- 完整 `swift test`、`Scripts/build-app.sh` 和差异检查。

工程验证通过只能说明代码、测试和构建门禁通过。

### 10.2 产品实操

使用最终打包 App 和代表性真实材料，至少覆盖：

- 一条有中文字幕的 B 站视频；
- 一条需要本机识别的 B 站视频；
- 一条小宇宙公开单集；
- 受限/失效链接；
- 未配置模型、错误凭据或不合法 JSON；
- 取消、重试、切换页面、退出重启；
- 提炼完成后审阅并写入笔记；
- 原始链接始终可回到来源；
- 连续处理多条材料时界面仍可响应，空闲时无持续重活。

产品实操必须观察用户能感知的反馈、等待、错误恢复和最终内容，不能只用 Mock 或 Accessibility Tree 替代。

### 10.3 用户验收

以下项目在用户本人实际使用并明确认可前保持 `UNVERIFIED`：

- 中文专名和时间戳文稿准确度；
- 摘要是否抓住真正重点；
- 去广告判断是否可靠；
- 等待感受、噪音和本机资源消耗是否可接受；
- 写入后的笔记结构是否适合继续编辑。

## 11. CC 候选处理结论

CC 当前未提交的 Slice A 候选方向可复用：域名纯函数分类、元数据成功时采用分类结果、元数据失败时保留已知 kind。

但它不能原样合入：新增测试当前因 `#expect` 注释参数类型错误而无法编译，而且同一工作区混有无关日历改动。实现阶段将在隔离分支按测试先行重新落地，只取已审过的行为，不复制脏工作区整体差异。
