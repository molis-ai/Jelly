# Grok 执行交接：通用材料提炼 Plan A

你是本轮实现者，Codex 是最终 reviewer。只执行 Plan A，不开始 Plan B/C。

## 工作目录与事实源

- 工作目录：`/Users/oreal/adeptify-home/worktrees/Jelly/codex-jelly-inspiration-material-digest`
- 当前分支：`codex/jelly-inspiration-material-digest`
- 起点 HEAD：`33c9284d23257f250c6bad2deab948139ae2b005`
- 产品设计：`docs/superpowers/specs/2026-08-24-universal-material-digest-design.md`
- 本轮唯一执行计划：`docs/superpowers/plans/2026-08-24-universal-material-digest-a-foundation.md`
- 后续计划 B/C 仅用于理解依赖，不得实现。

## 现有改动保护

进入时工作树已经有 10 个修改文件与 3 个未跟踪计划文件。这些是用户和前序 Agent 的候选工作，不是你的产出。

1. 先只读记录 `git status --short`、`git diff --stat` 和当前 HEAD。
2. 必须在这些改动之上最小增量实现，不得重置、还原、覆盖或清理现有改动。
3. 不得使用 `git reset`、`git checkout --`、`git restore`、`git clean`、rebase、stash 或任何会隐藏/丢失现有改动的操作。
4. 不修改三份计划、两份设计文档和本交接文档；如果计划本身存在阻断性矛盾，停止并在最终报告中说明，不得自行扩大方案。

## 实现范围

严格按 Plan A 的 Task 1—9 顺序，以测试驱动方式完成：

- `MaterialSnapshot`、typed blocks、locator、coverage 与 V3 证据类型；
- validator 与内容 checksum；
- Reducer 保存/复用/刷新快照状态；
- Workspace V4→V5 显式迁移；
- B 站与小宇宙按具体来源能力路由；
- Coordinator 先保存快照，再摘要，并复用未变化快照；
- 摘要协议升级为 V3 block 证据 JSON；
- 通用材料位置展示与笔记幂等；
- 生产装配、定向测试、完整测试和构建门禁。

保持既有产品合同：原始 URL 不丢；采集后由用户手动点“生成摘要”；派生摘要使用中文；原文引用和转写保持原语言；写入笔记必须由用户确认。

## 权限边界

- 可以修改 Plan A 明确列出的源码、测试和必要的工程装配文件，可以新增 Plan A 明确要求的文件。
- 不得提交、推送、合并、创建 PR、切换分支或创建/删除 worktree。
- 不得发布 App，不得改用户配置，不得访问 `~/.appkey/`，本阶段不做真实 MiniMax 或小红书联网测试。
- 不做无关重构，不新增 Python、yt-dlp、浏览器自动化或常驻服务。

## 验证与停止条件

每个 Task 先写失败测试，再做最小实现，再运行该 Task 指定测试。最后运行 Plan A 的完整门禁。测试失败时先判断是本轮回归、既有失败还是环境问题，不得为了变绿删除或弱化测试。

完成后立即停止，不开始 Plan B。最终报告必须包含：

1. 实际完成的 Task 1—9 状态；
2. 相对进入时基线新增/修改的文件；
3. 实际运行的每条测试/构建命令及结果；
4. 未解决问题、计划偏差和需要 Codex review 的风险；
5. 明确声明没有 commit/push/merge/PR。
