# Handoff：Jelly 灵感「URL → 提炼」

给下一个 agent 用。不要只读本文件就开工；先核对权威仓库现状，再问用户那条未决产品决策。

- **日期：** 2026-08-22
- **来源会话：** Grok Build `01a01070-b098-7920-8d24-df09f73f6c55`（2026-08-17 开始，最后活动 2026-08-19）
- **用户目标：** 把「随手丢进灵感的 B 站 / 小宇宙 / 文章 URL」变成可审阅摘要，再按需写入笔记
- **当前状态：** 只完成调研和接入方案，**没有写任何代码**
- **停点：** 等用户拍板「转成笔记时，原始 URL 怎么处理」

---

## 0. 给接盘 agent 的硬规则

1. **权威仓库：** `/Users/oreal/adeptify-home/repos/Jelly`  
   不要改 `/Users/oreal/Documents/Codex/2026-08-11/grok-https-github-com-adeptify-jelly/work/Jelly`。那是 8 月中的 Codex 工作副本，上一轮误读过。
2. **产品名：** 信息架构用「灵感」。代码、导航、页面标题里已经没有「灵光」。用户口语仍可能说「灵光」，当作同一模块。
3. **不要** 把下面两个 GitHub 网页应用嵌进 Jelly.app（不要起 FastAPI / Express、不要开 `:8000`、不要在页面里填 API Key）。
4. **不要** 把转录稿写进 `Inspiration.rawText`。`.url` 灵感禁止带正文，校验会拒绝。
5. **不要** 把模型输出当普通 `Block` 写进笔记正文却不留来源/草稿身份。规格 §10：AI 会话、建议、应用记录独立建模，不能覆盖原始灵感。
6. **不要** 在用户拍板第 8 节那条决策之前改领域合同或持久化 schema。
7. Jelly 是本地优先的 Apple silicon macOS 应用。识别层应是本机 Swift worker（WhisperKit / MLX），不是再装一套 Python 站。
8. 贴链接只做轻量元数据；提炼是详情里的明确动作，默认不要一粘贴就跑 Whisper。

---

## 1. 任务一句话

灵感已经能收 URL，但解析成功一律标成 `.article`，转笔记只生成一条 link block。缺的是规格里预留、README 也写了、但还没建的中间层：

```
source（原始 URL / 以后的文件）
  → digest（可审阅的文稿 + 结构化摘要，可失败、可重试）
  → wiki-style note（用户确认后才写）
```

用户的主源是 **B 站视频** 和 **小宇宙单集**，不是 YouTube。文章 URL 可以后做。

---

## 2. 参考过的两个开源项目（只借流水线，不搬仓库）

同一作者 [wendy7756](https://github.com/wendy7756)，官网宣传 [sipsip.ai](https://sipsip.ai)。

| | [AI-Video-Transcriber](https://github.com/wendy7756/AI-Video-Transcriber) | [podcast-transcriber](https://github.com/wendy7756/podcast-transcriber) |
|---|---|---|
| 角色 | 任意视频/播客链接 + 本地上传 → 文稿 + 摘要 | 播客链接 → 文稿 + 总结 |
| 技术 | Python / FastAPI，yt-dlp + Faster-Whisper | Node Express + 本地 Python Whisper |
| Stars（调研时） | ~3.2k | ~247 |
| 创建 | 2025-08-28 | 2025-08-22 |
| 用户该用它处理 | **B 站**（以及以后的 YouTube / 抖音） | **小宇宙**、Apple Podcasts、RSS |
| 明确不支持 | 小宇宙那套 RSS / `og:audio` 解析 | YouTube / B 站这类视频站 |

### 2.1 调研时的分流（个人使用这两个网页工具时）

- B 站视频页 → Video Transcriber，直接贴链接
- 小宇宙单集页 → Podcast Transcriber；解析失败则先拿到音频，再丢给 Video Transcriber
- 不要把小宇宙链接贴进视频仓，也不要把 B 站链接贴进播客仓

**接到 Jelly 之后不再开两个产品。** 一个后端、两个提取器（B 站字幕/yt-dlp 类 vs 小宇宙/RSS），后面共用同一套「文稿 → 结构化摘要」。

### 2.2 两个仓库真正的摘要逻辑

两边都不是「从音频直接听出摘要」。固定流水线：

```
链接/文件
  → 拿全文（有字幕就抽字幕；否则 Whisper）
  → 优化文稿（纠错、补句、分段）
  → 用优化后的文稿生成摘要
  → 源语言 ≠ 摘要语言时再全文翻译
```

| | Video Transcriber | Podcast Transcriber |
|---|---|---|
| 摘要口味 | 180–450 词执行简报，3–7 条 takeaway，禁止复述全文 | 按播客口语：去广告/片头片尾/赞助口播，保留观点 |
| 长文 | ~4000 token 切块，块摘要再合并 | ~6000 字切块 |
| 没 Key | 占位「API 不可用」摘要 | 总结失败 |
| 默认识别 | Faster-Whisper `base` + **强制 CPU int8** | 同样本地 Whisper |

### 2.3 2026 年视角下不该照搬的部分

产品形状（贴链接 → 文稿 + 摘要）仍成立。过时的是短窗口时代的拼法：

- 先全文润色再摘要再翻译：慢、贵、二次失真
- 默认 `base` Whisper + CPU：中文专名会烂，后面的「优化」是在修识别错误
- 视频仓字幕语言顺序 `en` 在 `zh-Hans` 前：B 站双语会先抽英文字幕
- 有字幕文件就跳过 Whisper：B 站 CC 经常是机翻/残缺，应先看覆盖率再决定
- 播客仓 `extractXiaoyuzhouAudio` 成功时有时 `return audioUrl`（字符串），上层读 `podcastInfo.audioUrl` 会当成失败——实打实的 bug
- 贴小宇宙**节目首页**会拿到 RSS 最新一集，不是当前集
- Key 从页面 Form 进后端 / `localStorage` 明文：Jelly 不能这么做
- 任务存在 `tasks.json`：同一 URL 的文稿没有落盘复用

**接到 Jelly 时该留的：**

- B 站：有靠谱中文字幕就抽字幕，没有再识别
- 小宇宙：单集页抽 `og:audio` / JSON-LD / RSS，不要依赖 yt-dlp
- 播客去广告规则（中插、片头片尾、赞助口播）写进摘要系统提示
- 视频仓的短结构化简报约束（论点 + 3–7 takeaway，禁止复述全文）

**接到 Jelly 时该丢掉的：**

- 两个 Web UI、双端口、页面填 Key
- 默认全文润色 + 全文翻译 + 4000 字切块
- 写死 `gpt-3.5` / `gpt-4`
- 把文稿塞进 `Inspiration.rawText`

更现在的摘要一次调用、出 JSON，不要自由散文：

```json
{
  "thesis": "...",
  "takeaways": ["...", "..."],
  "chapters": [{"t": "12:30", "title": "...", "points": ["..."]}],
  "quotes": [{"speaker": "...", "t": "18:02", "text": "..."}],
  "entities": {"people": [], "books": [], "numbers": []},
  "dropped": ["中插广告：..."]
}
```

有时间戳才能回原文；有 `dropped` 去广告才可检查。

---

## 3. 权威文档与代码（先读这些）

仓库 HEAD 在写本 handoff 时：`main` / `e2746f2`（Jelly 0.3.4），与 `origin/main` 同步。

| 文件 | 为什么读 |
|---|---|
| [README.md](../../README.md) | Next 明确写了 `source → digest → wiki-style notes`，**未做** |
| [2026-08-09 灵感设计规格](../superpowers/specs/2026-08-09-workspace-notes-inspiration-design.md) | 合同。尤其 §4.6 灵感模型、§6.3 URL 保存顺序、§10 未来 AI、§11 第一阶段范围 |
| [2026-08-14 9 分体验方案 §5.8](../product/2026-08-14-jelly-9-point-product-experience-plan.md) | 灵感收件箱体验；名称已统一为「灵感」 |
| `Sources/WorkspaceDomain/Inspiration.swift` | `CaptureInputKind` / `ResolvedSourceKind` / `SourceMetadata` |
| `Sources/WorkspaceDomain/WorkspaceReducer+Inspiration.swift` | 入箱、元数据 checksum 门、转笔记、归档 |
| `Sources/WorkspaceDomain/WorkspaceValidator.swift` | `.url` 不能有 `rawText` |
| `Sources/WorkspaceDomain/WorkspaceChecksum.swift` | `inspirationSourceChecksum`：只 hash 原始输入，不含元数据 |
| `Sources/WorkspaceDomain/WorkspaceState.swift` | 当前没有 digest 集合 |
| `Sources/CalendarPersistence/WorkspaceDocument.swift` | **当前 schemaVersion = 4**（规格里写的 V3 已过期） |
| `Sources/CalendarApp/Inspiration/InspirationViewModel.swift` | 捕获、异步 enrich、转笔记只写一条 link |
| `Sources/CalendarApp/Inspiration/URLMetadataResolver.swift` | 成功一律 `resolvedKind: .article` |
| `Sources/CalendarApp/Inspiration/InspirationSplitView.swift` | 详情 UI |

规格里和本任务直接相关的原话：

- §4.6：URL 是文章、帖子、视频还是音频，由解析结果决定，用户不预先选。`.file` 为首版之后的材料输入保留合同。
- §6.3：先原子保存原始 URL 与 `.unknown` → 异步解析元数据 → 失败保留原 URL 可重试。**第一阶段不抓取全文、不生成摘要，也不把网络错误描述成 AI 处理结果。**
- §10：后续包括「对文章、音频、视频和文件生成带来源的提炼结果」。AI 不能塞进 `BlockDocument` 当不可区分正文，也不能覆盖原始灵感。
- §11.1 包含 URL 基础元数据的失败安全解析；AI / 全文提炼不在 V1。

---

## 4. 当前实现（写本文件时核对过）

### 4.1 已经有的

- 灵感 raw-first 收件箱：文字 / URL 入箱、待处理 / 已成笔记 / 归档、转笔记、归档、恢复、永久删除墓碑。
- UI 名称已统一为「灵感」（Swift 源码里 0 处「灵光」）。
- `ResolvedSourceKind` 已有 `.video` / `.audio` / `.article` / `.unknown` 等。
- URL 入箱立即 commit，`fetchStatus = .loading`，后台 `enrichURL`。
- 元数据更新走 `inspirationSourceChecksum`：源变了则 `.staleMetadata`，失败只改状态，**不删 rawURL**。
- 转笔记：同一灵感只建一篇 Note + `InspirationNoteLink`；重复点进入已有笔记。

### 4.2 明确没有的

- `MaterialDigest` 或任何 transcript / summary 领域对象
- `WorkspaceState` 里没有 digest 集合
- 域名分类：B 站 / 小宇宙不会变成 `.video` / `.audio`
- 字幕抽取、音频下载、Whisper、LLM 摘要
- 详情里的「提炼」按钮
- 转笔记时写入摘要结构

### 4.3 关键代码事实

**捕获 URL**（`InspirationViewModel.capture`）：`http/https` → `.url`，`resolvedSourceKind = .unknown`，元数据 `loading`，然后 `Task { enrichURL }`。

**解析**（`URLMetadataResolver.resolve`）：

- GET HTML，8s 超时，256 KB 上限，不带 cookie
- MIME 必须是 `text/html` 或 `application/xhtml+xml`，否则 `unsupportedContentType`
- 只抽 `<title>`
- **返回 `resolvedKind: .article`，没有域名判断**

后果：B 站 / 小宇宙即使解析成功也会被当成文章。很多播放页根本不是规整 HTML（或体积/类型不对），会失败并停在 `.unknown`。提炼入口按 kind 挂的话，这两类源现在都挂不上。

**转笔记**（`document(for:)`）：

- URL 灵感 → 单个 `.link` block（标题或 URL 字符串 + `linkURL`）
- 文字灵感 → 单个 `.paragraph`
- 没有摘要、没有章节、没有「原文在上、提炼在下」

**校验**（`WorkspaceValidator`）：`.url` 必须有可解析 `rawURL`，且 `rawText == nil`、无 `rawFile`。把 Whisper 文稿写进 `rawText` 会直接 invalid。

**Checksum：** `inspirationSourceChecksum` 只覆盖 id + inputKind + 原始 text/url/file。Digest 必须另存自己的 `sourceChecksum`，用同一函数，防止用户改 URL 后旧摘要写回来。

**持久化：** `WorkspaceDocument.currentSchemaVersion = 4`。加 digest 集合必须显式 DTO 迁移到 5，禁止靠新字段默认值猜旧数据。规格 §8.1 写的 schema 3 是历史，不要按 3 做。

---

## 5. 已达成的产品结论（用户未反对）

上一轮在「我是想把这套能力接入 jelly 的灵感模块」之后给出方案，用户没有否定。当作**待确认的工作假设**，不要写成用户签字的合同；但也不要重新发明一轮。

1. **不新开转录 App / 不新开一级 Tab。** 能力落在灵感详情。
2. **灵感仍是原料，笔记仍是成品。** Digest 是过程产物，状态独立，像元数据一样异步、可失败、可重试。
3. **默认手动点「提炼」。** 粘贴只做轻量元数据，避免收件箱被识别打满。符合「AI 只提交建议」。
4. **第一期源：B 站 + 小宇宙单集。** 文章全文、文件、说话人分离、对着这集提问、知识库图谱、自动转笔记、全文翻译都不做。
5. **B 站：中文字幕优先**，不要抄 Video Transcriber 的 `en` 在前。字幕质量差再抽音识别。
6. **小宇宙：原生抽音频**（`og:audio` / JSON-LD / 单集 RSS）。节目首页不要当单集。不要依赖 yt-dlp。
7. **识别：** WhisperKit / MLX，至少 `large-v3-turbo`。不要默认 `base` + CPU。
8. **摘要：** 用户自己的 OpenAI 兼容 Key，一次长上下文调用出 JSON。小宇宙带去广告规则。
9. **UI：** 左栏三态不变。右栏原文下面加提炼区（未跑 / 进行中 / 成功 / 失败）。徽标仍只算没笔记的灵感。Digest 失败不要冒充入箱失败。
10. **写入笔记仍要用户确认。** 全文稿默认留在 Digest 里折叠，不要一转换就灌进笔记。

建议的对象（上一轮草案，落地前要编进领域合同并补校验）：

```swift
struct MaterialDigest {
    let id: MaterialDigestID
    let inspirationID: InspirationID
    let sourceChecksum: String          // WorkspaceChecksum.inspirationSourceChecksum
    var status: idle | running | succeeded | failed
    var transcript: TimestampedTranscript?   // 可折叠，不当笔记正文
    var summary: InspirationSummary?
    var modelProvenance: ...                 // 模型、时间、输入指纹
    var failureReason: String?
}

struct InspirationSummary {
    var thesis: String
    var takeaways: [String]              // 3–7
    var chapters: [(t: String, title: String, points: [String])]
    var quotes: [(speaker?: String, t: String, text: String)]
    var dropped: [String]                // 广告 / 片头片尾
}
```

建议的流水线：

```
贴 B站 / 小宇宙链接
  → 立刻写入 Inspiration（raw URL，kind = .unknown）
  → 轻量解析：标题 + 判成 video / audio（不要当 article 去扒整页当正文）
  → 用户在详情点「提炼」
  → MaterialDigest：running → 文稿 + JSON 摘要
  → 详情审阅
  → 「写入笔记」才走现有 convertInspirationToNote / InspirationNoteLink
```

和现有 URL 元数据同一纪律：先原子保存原文 → 再异步处理 → checksum 防过期写入 → 失败只改状态。

---

## 6. 第一期范围 / 明确不做

**做：**

1. 域名分类，B 站 → `.video`，小宇宙单集 → `.audio`，不再一律 `.article`
2. `MaterialDigest` 领域对象 + checksum + 失败安全 + schema 迁移
3. B 站字幕优先（中文）/ 小宇宙取音频
4. 本机识别 + 一次 JSON 摘要
5. 详情审阅 → 接到已有「转成笔记」

**不做：**

- 嵌两个 GitHub 仓库或它们的 Web UI
- 聊天问这集 / RAG
- 知识库图谱
- 自动转笔记
- 全文翻译
- 双人说话人（WhisperX / pyannote）——可留扩展点
- 大会员 / cookies.txt（允许以后；第一期失败时走 `.file` 合同或提示用户）
- 小宇宙节目首页「帮我猜是哪一集」
- 把模拟 AI / 假摘要做成一级入口（9 分方案：没有真实能力就不要装成熟）

---

## 7. 建议的实现顺序（决策通过之后）

不要一上来接 Whisper。分类错了，后面全挂在错误 kind 上。

### Slice A — 分类（可单独合入，不碰 AI）

改 `URLMetadataResolver`（或在它前面加一层纯函数）：

| URL | kind |
|---|---|
| `bilibili.com` / `b23.tv` 的视频页 | `.video` |
| `xiaoyuzhoufm.com/episode/…` | `.audio` |
| 小宇宙节目首页 `/podcast/…` | `.unknown` 或单独失败语义，**不要**当成单集 |
| 其它能抽到 HTML title 的 | 保持现在的 `.article` |
| 非 HTML / 超时 / 过大 | 保持失败 + 原 URL，kind 仍 `.unknown`，除非域名已经能判 |

域名判断应在发 GET 之前就能做。B 站播放页经常不是「一篇文章 HTML」，现在的 MIME/HTML 路径会失败，连 kind 都留不下。

测试：纯函数表格，不打网络。现有 enrich 失败安全测试必须继续绿。

### Slice B — `MaterialDigest` 合同

- 新 ID 类型、status 枚举、checksum 门、与 Inspiration 的 1:1 或 1:N（第一期 1:1 足够：同一 sourceChecksum 覆盖写，checksum 变了旧 digest 作废）
- `WorkspaceState` 增加集合
- `WorkspaceDocument` schema 4 → 5，显式 DTO 迁移，旧文档 digest 为空
- Validator：digest 必须指向存在的 inspiration；checksum 对不上则不能标 succeeded
- Reducer 命令建议：`startDigest` / `completeDigest` / `failDigest` / `retryDigest`，都走 checksum
- UI：详情出现「提炼」仅当 kind ∈ {video, audio}（文章全文第一期不做）
- 仍不调用模型。可用 fixture resolver 把一条 B 站 URL 跑到 succeeded，确认失败不会动 rawURL

### Slice C — 取文本

- B 站：中文字幕优先；评估字幕质量；差则抽音（本机，用户可见进度）
- 小宇宙：`og:audio` / JSON-LD / 单集 RSS；修「返回字符串被当成失败」这类问题；禁止把节目首页当单集
- 进度文案区分：取字幕 / 取音频 / 识别 / 摘要
- 可取消；取消后 inspiration 不变

### Slice D — 识别 + 摘要

- WhisperKit / MLX，`large-v3-turbo` 起步
- 用户配置 OpenAI 兼容端点（设置里，内存/钥匙串，不要 localStorage 明文、不要塞进每条请求的表单）
- 一次 JSON 摘要；小宇宙系统提示带去广告；视频带短简报约束
- provenance：模型名、时间、输入指纹
- 没 Key：明确失败「未配置模型」，不要生成假摘要

### Slice E — 写入笔记

等第 8 节决策。推荐实现见下。

---

## 8. 未决决策（开工前必须问用户）

上一轮停在这一句，用户**没有回答**：

> 第一期「写入笔记」是替换现在那条光秃链接，还是保留原始链接、把提炼追加成可审阅草稿？

**推荐：保留原始 URL 为笔记里的来源 block，提炼作为其后的可审阅草稿结构写入。**

理由：

- 和规格「不覆盖原文」一致
- 笔记里永远留得住可点击的原始材料
- 摘要看错了还能回到源
- 现有 `convertInspirationToNote` 已经创建 link block，追加比替换安全

若用户选「替换」：笔记正文以 thesis + takeaways 为主，URL 只进元数据/来源引用，不当可见 block。不推荐，除非用户明确要干净笔记。

**问的时候只问这一件。** 问完再动 schema / reducer。

其它可以以后再问、第一期用默认值的：

- 是否允许设置里「粘贴后自动提炼」（默认关）
- B 站分 P：第一期只处理落地页对应分 P
- Key 放系统设置还是灵感模块设置（倾向 App 级设置）

---

## 9. 工程约束备忘

- 语言：Swift，SPM。UI 在 `CalendarApp`，合同在 `WorkspaceDomain`，持久化在 `CalendarPersistence`。
- 命令必须进 reducer + validator + undo；视图不得直接改集合。
- 现有测试风格：领域单测 + 失败安全（checksum / stale / 不覆盖原文）。新能力照抄元数据那套，不要只测 happy path。
- 性能：灵感列表 100 条时捕获和切换仍要即时。重活不得阻塞主线程，不得在 `capture()` 里 await Whisper。
- 本地优先：数据留在 Mac。模型 Key 是用户的。不要把音视频传到你们自己的服务器（当前产品没有这种后端）。
- Apple silicon + macOS 14+。不要为 Intel 做第一期方案。
- 打包：`Scripts/build-app.sh`。不要把 Python venv 塞进 `.app`。
- 中文 UI 文案。按钮用「提炼」还是「生成摘要」：上一轮用「提炼」，与规格「提炼结果」一致。

---

## 10. 上一轮会话里的用户原话（按时间）

1. `https://github.com/wendy7756/AI-Video-Transcriber 介绍一下这个项目`
2. `你再介绍一下 podcast transcriber 吧，这两个仓库解决问题的差异是什么`
3. `我的主要源是小宇宙和 b 站，我应该怎么用？`
4. `你把这两个仓库分别支持的源都给我列一下`
5. `ok，大致的用法就是，丢链接，然后 AI 就能生成摘要对吧？这个摘要和总结的逻辑是什么`
6. `ok，因为这两个仓库其实已经算是比较老的，你用你最新模型的视角来审视一下，有没有可以优化的地方啊？`
7. `我是想把这套能力接入 jelly的灵感模块`

第 7 条之后是方案 + 等待第 8 节决策。没有第 8 条用户回复。没有 commit。

会话摘要字段：`Need decision: keep URL, append digest draft to notes`。

---

## 11. 建议的接盘开场

对用户说：

1. 已读本 handoff。
2. 复述：接到灵感，不嵌那两个网页工具；第一期 B 站 + 小宇宙；提炼手动点。
3. **只问一件事：** 转成笔记时，保留原始链接并把摘要追加进笔记，还是用摘要替换那条光秃链接？（推荐前者。）
4. 用户定了之后从 Slice A（域名分类）开始，权威仓库 `~/adeptify-home/repos/Jelly`。

不要在开场重做两个 GitHub 仓库的竞品调研，除非用户改了源。
