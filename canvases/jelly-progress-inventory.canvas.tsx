import {
  Card,
  CardBody,
  CardHeader,
  CollapsibleSection,
  Divider,
  Grid,
  H1,
  H2,
  H3,
  Row,
  Stack,
  Stat,
  Table,
  Text,
  useHostTheme,
} from "cursor/canvas";

type ReactNode = Parameters<typeof Stack>[0]["children"];

type Status = "done" | "partial" | "missing" | "skip";

type Step = {
  name: string;
  status: Status;
  note: string;
};

type Loop = {
  title: string;
  goal: string;
  usage: string;
  steps: Step[];
};

const loops: Loop[] = [
  {
    title: "日历 + 清单",
    goal: "替代滴答：只留日历和清单，轻、快、稳",
    usage: "截至 2026-09-23：36 天 58 条，近 7 天 21 条。本次没有重读你的数据",
    steps: [
      { name: "看日程", status: "done", note: "月 / 周 / 日期抽屉、拖拽、分类颜色、置顶、优先级、复制到当天、撤销、⌘K 全局查找" },
      { name: "快速记一条", status: "done", note: "标题里直接写“明天下午 3 点开会”“周五 15:00-16:30”“今晚8点提醒我…”，保存前预览识别结果，可点“按原样”" },
      { name: "无日期清单", status: "done", note: "日历工具栏“清单”打开“以后再说”：加一件没定日期的事，写了日期会直接进日历；一键安排到今天 / 明天" },
      { name: "手机提醒", status: "partial", note: "事项可设提醒，Mac 写进“提醒事项”的 Jelly 列表经 iCloud 响；iPhone 发本地通知。真实写入需要你在系统弹窗里允许，还没实测" },
      { name: "完成与顺延", status: "skip", note: "你按天记录就够，不需要“完成”；现有勾选保持不动" },
      { name: "手机上看 / 记", status: "partial", note: "iOS App 已合入 main 分支线，能同步、能从 Siri / 分享表单收下；本机没有 Xcode，只做了 macOS SDK 类型检查，没在模拟器或真机跑" },
    ],
  },
  {
    title: "灵感",
    goal: "最低成本收下 → AI 补充延展 → 回头看 → 链到待办",
    usage: "9 条灵感停在 2026-08-26（未重读）。新入口要装上 0.4.0 才有",
    steps: [
      { name: "随手收下", status: "done", note: "Mac：任何 App 里按 ⌃⌥J 弹小窗、回车收下；右键 › 服务 › 收进 Jelly 灵感；菜单栏灯泡。iPhone：Siri“用 Jelly 记灵感”、分享表单快捷指令、截图 / 文件收进材料" },
      { name: "原样保留", status: "done", note: "文字、链接、文件原样保存，链接自动取标题和站点；延展和看法都另存，不改原文" },
      { name: "AI 补充延展", status: "done", note: "收下后自动补一句、给 2–3 个方向，逐条采纳 / 忽略 / 变成待办；用摘要设置里的模型（本机 Codex 实测通过）" },
      { name: "回头看", status: "done", note: "超过约一天没处理的灵感按最早优先带回来，逐条留着 / 变成待办 / 丢掉；每天一条安静提示，可选 21:00 经提醒事项提醒" },
      { name: "链到待办", status: "done", note: "详情页“安排”：今天 / 明天 / 选一天 / 无日期清单，一步变成待办，不再必须先转笔记" },
    ],
  },
  {
    title: "材料 → 知识",
    goal: "丢进一份材料 → 帮你消化、管理 → 形成自己的观点",
    usage: "提炼记录截至 2026-09-23 是 0（未重读）",
    steps: [
      { name: "丢进材料", status: "done", note: "网页 / PDF、截图 OCR、小红书、B 站、播客；公众号改为专门抽取 #js_content，两篇真实文章抽出 2398 / 6203 字正文" },
      { name: "AI 消化", status: "done", note: "摘要、延展、拆开并安排、追问与综合都读同一套设置：云端预设 + Key，或本机已登录的 Codex / Claude；本机 claude 未登录时会明确提示" },
      { name: "关联管理", status: "partial", note: "灵感可转笔记或直接变待办，笔记有单层分类；笔记之间仍不能互链，没有反向链接" },
      { name: "知识图谱", status: "missing", note: "没有（不在这次清单里）" },
      { name: "形成观点", status: "done", note: "提炼完成后有“我的看法”，可让模型追问；两份以上已提炼材料可生成综合笔记（共同指向、分歧、待追问题、立场草稿）" },
    ],
  },
];

const statusLabel: Record<Status, string> = {
  done: "已满足",
  partial: "部分",
  missing: "没有",
  skip: "你不需要",
};

function StatusMark({ status }: { status: Status }) {
  const theme = useHostTheme();
  const color =
    status === "done"
      ? theme.category.green
      : status === "partial"
        ? theme.category.orange
        : status === "missing"
          ? theme.category.red
          : theme.text.quaternary;
  return (
    <Row gap={6} align="center">
      <span
        style={{
          display: "inline-block",
          width: 8,
          height: 8,
          borderRadius: 4,
          background: status === "done" || status === "partial" ? color : "transparent",
          border: `1.5px ${status === "skip" ? "dashed" : "solid"} ${color}`,
        }}
      />
      <Text size="small" tone="secondary">
        {statusLabel[status]}
      </Text>
    </Row>
  );
}

function LoopStrip({ loop }: { loop: Loop }) {
  const theme = useHostTheme();
  const counts = loop.steps.reduce(
    (acc, s) => ({ ...acc, [s.status]: acc[s.status] + 1 }),
    { done: 0, partial: 0, missing: 0, skip: 0 } as Record<Status, number>,
  );
  return (
    <Card>
      <CardHeader
        trailing={
          <Text size="small" tone="tertiary">
            已满足 {counts.done} · 部分 {counts.partial} · 没有 {counts.missing}
            {counts.skip > 0 ? ` · 你不需要 ${counts.skip}` : ""}
          </Text>
        }
      >
        {loop.title}
      </CardHeader>
      <CardBody>
        <Stack gap={12}>
          <Stack gap={2}>
            <Text tone="secondary">{loop.goal}</Text>
            <Text size="small" tone="tertiary">
              实际使用：{loop.usage}
            </Text>
          </Stack>
          <Grid columns={loop.steps.length} gap={8} align="stretch">
            {loop.steps.map((step, i) => (
              <div
                key={step.name}
                style={{
                  padding: 10,
                  borderRadius: 6,
                  border: `1px solid ${theme.stroke.tertiary}`,
                  background: step.status === "missing" || step.status === "skip" ? "transparent" : theme.fill.quaternary,
                  opacity: step.status === "skip" ? 0.6 : 1,
                }}
              >
                <Stack gap={6}>
                  <Text weight="semibold">
                    {i + 1}. {step.name}
                  </Text>
                  <StatusMark status={step.status} />
                  <Text size="small" tone="secondary">
                    {step.note}
                  </Text>
                </Stack>
              </div>
            ))}
          </Grid>
        </Stack>
      </CardBody>
    </Card>
  );
}

function Finding({ title, children }: { title: string; children: ReactNode }) {
  const theme = useHostTheme();
  return (
    <div style={{ borderTop: `2px solid ${theme.accent.primary}`, paddingTop: 10 }}>
      <Stack gap={6}>
        <H3>{title}</H3>
        {children}
      </Stack>
    </div>
  );
}

function GapColumn({ title, hint, items }: { title: string; hint: string; items: { name: string; why: string }[] }) {
  const theme = useHostTheme();
  return (
    <Stack gap={10}>
      <Stack gap={2}>
        <Text weight="semibold">{title}</Text>
        <Text size="small" tone="tertiary">
          {hint}
        </Text>
      </Stack>
      {items.map((item) => (
        <div key={item.name} style={{ paddingLeft: 10, borderLeft: `2px solid ${theme.stroke.secondary}` }}>
          <Stack gap={2}>
            <Text>{item.name}</Text>
            <Text size="small" tone="secondary">
              {item.why}
            </Text>
          </Stack>
        </div>
      ))}
    </Stack>
  );
}

export default function JellyProgressInventory() {
  const theme = useHostTheme();
  return (
    <Stack gap={28} style={{ padding: 24, maxWidth: 1180 }}>
      <Stack gap={6}>
        <H1>Jelly 现状盘点：离你要的样子还差什么</H1>
        <Text size="small" tone="tertiary">
          依据：分支 claude/inventory-followup（合入 codex/jelly-ios 后的 13 个提交，打包为 0.4.0）、自动化测试、隔离数据下的真实打包实测，以及 2026-09-23 的数量统计（未重读内容）· 2026-09-29
        </Text>
      </Stack>

      <div style={{ padding: "16px 18px", borderRadius: 8, background: theme.fill.tertiary }}>
        <Stack gap={8}>
          <Text weight="semibold" style={{ fontSize: 16, lineHeight: 1.55 }}>
            “当前必须”和“可以延后”都已做进代码。剩下的是三件只有你能做的验收。
          </Text>
          <Text tone="secondary" style={{ lineHeight: 1.6 }}>
            灵感现在能在任何 App 里一键收下、自动补一句、定期被带回来、一步变成待办；日历能直接写“明天下午 3 点开会”，有了无日期清单和提醒；拆解、观点和综合都用你选的模型；Mac 和 iPhone 可以经 iCloud Drive 文件夹同步。还需要你：装上 0.4.0；在设置 › 提醒里允许一次“提醒事项”权限，看手机是否响；在真机或模拟器上跑一次 iOS App。
          </Text>
        </Stack>
      </div>

      <Stack gap={10}>
        <H2>你的真实使用</H2>
        <Grid columns={6} gap={12}>
          <Stat value="58" label="日历事项（截至 9 月 23 日）" />
          <Stat value="21" label="当时近 7 天新建" />
          <Stat value="52 / 58" label="全天事项（按天记录）" />
          <Stat value="9" label="灵感，停在 8 月 26 日" tone="warning" />
          <Stat value="0" label="灵感转成笔记" tone="danger" />
          <Stat value="0" label="当时的提炼记录" tone="danger" />
        </Grid>
        <Text size="small" tone="tertiary">
          数量没有重算。另有：6 条定了具体时间；没有一条勾过完成；笔记 2 篇；重复系列 0 个。这些数字截止 2026-09-23。
        </Text>
      </Stack>

      <Stack gap={12}>
        <H2>三条链路各走到哪一步</H2>
        {loops.map((loop) => (
          <LoopStrip key={loop.title} loop={loop} />
        ))}
      </Stack>

      <Stack gap={14}>
        <H2>三个贯穿性发现</H2>
        <Grid columns={3} gap={24}>
          <Finding title="一套模型设置，四处在用">
            <Text tone="secondary" style={{ lineHeight: 1.6 }}>
              延展、拆开并安排、观点追问、跨材料综合和摘要都走同一个路由：选了本机命令就只用本机，找不到或没登录会直说，不会悄悄改用云端。拆解在这台 M5 上不再是“设备不支持”。
            </Text>
            <Text size="small" tone="tertiary">
              本机实测：Codex 延展、Codex 拆解通过；这台机器的独立 claude 命令未登录，已按“未登录”提示处理。
            </Text>
          </Finding>
          <Finding title="捕获到了想法冒出来的地方">
            <Text tone="secondary" style={{ lineHeight: 1.6 }}>
              Mac 上不用切到 Jelly：快捷键小窗、右键服务、菜单栏。手机上：Siri 口述、分享表单里的快捷指令、截图直接当材料。两端通过同一个 iCloud Drive 文件夹同步，每台设备只写自己的文件。
            </Text>
          </Finding>
          <Finding title="能用了，还没被用起来">
            <Text tone="secondary" style={{ lineHeight: 1.6 }}>
              你的日常数据里灵感仍停在 8 月，提炼仍是 0。0.4.0 数据格式升到 6，旧版会拒绝打开而不是悄悄丢字段；装上后先让“回顾”把那 9 条旧灵感带回来过一遍。
            </Text>
          </Finding>
        </Grid>
      </Stack>

      <Divider />

      <Stack gap={14}>
        <Stack gap={4}>
          <H2>盘点清单的完成情况</H2>
          <Text size="small" tone="tertiary">
            “当前必须”与“可以延后”全部实现；“应当收起”的三项这次没有动，另加一条待你决定的。
          </Text>
        </Stack>
        <Grid columns={3} gap={28}>
          <GapColumn
            title="当前必须 · 已完成"
            hint="括号里是验证方式"
            items={[
              { name: "Mac 上随手收下", why: "⌃⌥J 小窗 / 右键服务 / 菜单栏（单测；真实打包经系统 Services 收下并延展）" },
              { name: "手机上把东西丢进来", why: "App Intents + App Shortcuts，文字、链接、文件（macOS SDK 类型检查，未在 iOS 运行）" },
              { name: "回头看", why: "按最早优先逐条三选一，每日提示，可选 21:00 提醒（单测 + 离屏渲染）" },
              { name: "灵感延展", why: "补一句 + 2–3 个方向，采纳 / 忽略 / 变成待办（单测；真实打包用本机 Codex 生成）" },
              { name: "手机提醒", why: "Mac 写提醒事项 Jelly 列表，iPhone 本地通知（假网关单测；系统权限需你本人允许后实测）" },
            ]}
          />
          <GapColumn
            title="可以延后 · 已完成"
            hint="同样都进了代码"
            items={[
              { name: "拆解改到同一套设置", why: "配了模型就用它，没配才用 Apple 端侧；超时 90 秒（本机 Codex 拆出 3 个行动）" },
              { name: "无日期清单、自然语言快速添加", why: "中文日期时间解析 + “以后再说”面板（单测覆盖常见说法）" },
              { name: "灵感直接安排到某天", why: "详情页“安排”，回顾里“变成待办”（单测，可撤销）" },
              { name: "公众号正文抽取", why: "专门适配器，8 MB 上限，只读正文（两篇真实文章联网实测）" },
              { name: "观点与跨材料综合", why: "“我的看法”+ 追问，综合笔记（单测，离屏渲染）" },
              { name: "Mac 与 iPhone 同步", why: "iCloud Drive 文件夹，逐记录合并 + 冲突副本（9 个引擎场景 + 真实打包两实例互通）" },
            ]}
          />
          <GapColumn
            title="应当收起或重新评估"
            hint="这次没有动"
            items={[
              {
                name: "“完成”相关的统计",
                why: "本周回顾里的完成 / 未完成 / 延期数，对不勾完成的你没有意义",
              },
              {
                name: "继续扩提炼来源",
                why: "来源已齐，公众号补上了；重点改成把手机上的收藏送进来",
              },
              {
                name: "把 Whisper 当默认转写",
                why: "默认已是系统语音，然后 SenseVoice。Whisper 只在 Mac 上单独打开",
              },
              { name: "无日期清单与 Todo 插件重叠", why: "Molis Work 里的 Todo 计划做唯一正式待办；Jelly 这份清单是否保留，由你决定" },
            ]}
          />
        </Grid>
        <div style={{ padding: "12px 14px", borderRadius: 6, background: theme.fill.quaternary }}>
          <Stack gap={4}>
            <Text weight="semibold">还需要你本人做的</Text>
            <Text size="small" tone="secondary" style={{ lineHeight: 1.6 }}>
              1. 用 Scripts/install-desktop-app-safely.sh 装上 dist/Jelly.app（0.4.0，会先备份应用和数据）。2. 设置 › 提醒 打开，系统弹窗点允许，给明天的事项设个提前 5 分钟，看 iPhone 是否响。3. 在装了 Xcode 的机器上跑 Scripts/build-ios.sh 和 test-ios-ui.sh，并在快捷指令里把“收进 Jelly 灵感”放进分享表单试一次。4. 两端设置 › 同步 选同一个 iCloud Drive 文件夹。
            </Text>
          </Stack>
        </div>
      </Stack>

      <Card>
        <CardHeader>你的回答，以及后来实际做了什么</CardHeader>
        <CardBody>
          <Table
            framed={false}
            headers={["问题", "你的回答", "现在的状态"]}
            rows={[
              ["58 条事项为什么没勾过完成", "不需要“完成”，按天记录就够", "完成统计仍应收起，这次没改"],
              ["在滴答里依赖提醒吗", "依赖，主要靠手机", "已做：Mac 经提醒事项 + iCloud，iPhone 本地通知；等你允许权限后实测"],
              ["灵感在哪儿冒出来", "手机和 Mac 差不多一半一半，也想用语音", "Mac 快捷键 / 服务 / 菜单栏；iPhone Siri 口述、分享表单；两端可同步"],
              ["最常收藏哪几类", "小红书、公众号、播客、B 站、网页、截图都有", "公众号补上专门抽取；手机截图可直接当材料收下"],
              ["AI 用哪家", "用户自选，自带 Key", "预设 + Key 或本机 Codex / Claude；延展、拆解、观点、综合都已迁过来"],
            ]}
          />
        </CardBody>
      </Card>

      <CollapsibleSection title="代码与验证依据">
        <Table
          headers={["结论", "依据"]}
          rows={[
            ["自动化测试", "领域、日历、持久化、MCP 四个测试目标 533 个用例全部通过。App 目标一次跑不完（main 上同样中途退出），分批对照 main：失败项与 main 相同（深色外观、性能门槛、2 条摘要测试、2 条依赖 1 秒时序的偶发界面测试）。新增 69 个用例（其中 5 个用环境变量开启的实测与验收工具）全部通过"],
            ["iOS 代码", "Scripts/test-ios-shared.sh：78 个共享源码 + 意图、提醒、同步、清单视图在 macOS SDK 下类型检查，移动端持久化冒烟通过；未在 iOS SDK 构建"],
            ["真实打包：服务菜单 → 延展", "dist/Jelly.app 0.4.0 在隔离数据下，经 NSPerformService 收下一句话，本机 Codex 写回 1 句补充 + 3 个方向（local/codex）"],
            ["真实打包：同步", "两个隔离实例共用一个文件夹：空白一方收到 7 条灵感、事项（含提前 10 分钟提醒）、2 条无日期事项；“未分类”收敛到同一个 id"],
            ["真实联网：公众号", "两篇公开文章抽出 2398 / 6203 字正文，带公众号名与发布日期"],
            ["真实本机模型", "JELLY_RUN_LIVE_LOCAL=1：Codex 延展、Codex 拆解通过；独立 claude 命令未登录，提示为“本机命令还没有登录”"],
            ["界面", "InventorySnapshotRenderer 离屏渲染回顾、延展、随手记、清单、提醒、同步、综合（浅 / 深色）并逐张查看；未在屏幕上实操（你没有授权界面操作）"],
            ["数据格式", "schema 6：schema 5 原样读取、新字段为空；旧版读到 6 会拒绝打开，不会悄悄丢字段"],
            ["同步设计", "docs/sync.md：每台设备只写自己的文件，逐记录后写者胜 + 墓碑 + 已见向量，并发笔记保留冲突副本"],
            ["本次发现并修掉", "服务菜单端口名不对；本机 claude 未登录被误报为格式错误；后台服务改为不依赖主窗口启动（防御性）"],
          ]}
        />
      </CollapsibleSection>
    </Stack>
  );
}
