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
    usage: "截至 2026-09-23：36 天 58 条，近 7 天 21 条。这仍是唯一真正在用的部分",
    steps: [
      { name: "看日程", status: "done", note: "月 / 周 / 日期抽屉、拖拽、分类颜色、置顶、优先级、复制到当天、撤销、⌘K 全局查找" },
      { name: "快速记一条", status: "partial", note: "点日期再输入标题；不认“明天下午 3 点开会”这类自然语言" },
      { name: "无日期清单", status: "missing", note: "每条事项都必须有日期，没有“收件箱 / 以后再说”" },
      { name: "手机提醒", status: "missing", note: "Mac 和 iOS 都没有通知。你在滴答里主要靠手机提醒，这仍是替代滴答最实际的缺口" },
      { name: "完成与顺延", status: "skip", note: "你按天记录就够，不需要“完成”；现有勾选保持不动" },
      { name: "手机上看 / 记", status: "partial", note: "iOS App 已在 codex/jelly-ios，模拟器能编过。和 Mac 的数据不相通，也不读写系统日历" },
    ],
  },
  {
    title: "灵感",
    goal: "最低成本收下 → AI 补充延展 → 回头看 → 链到待办",
    usage: "9 条灵感都记在 2026-08-23 至 26 日，统计截止日之后没有新的使用记录；没有再编辑、转化或归档",
    steps: [
      { name: "随手收下", status: "missing", note: "仍要打开 Jelly 再进灵感页。没有全局快捷键、菜单栏、分享菜单或微信入口。手机 App 有灵感页，但不能从别的 App 丢进来" },
      { name: "原样保留", status: "done", note: "文字、链接、文件原样保存，链接自动取标题和站点" },
      { name: "AI 补充延展", status: "missing", note: "纯文本灵感仍不经过 AI。摘要设置已经有了，但“补一句、给方向”还没接上这套设置" },
      { name: "回头看", status: "missing", note: "没有回顾节奏，也没有把旧灵感带回眼前的机制" },
      { name: "链到待办", status: "partial", note: "仍是先转成笔记，再在笔记里拆开并安排。拆解还是 Apple 端侧模型，这台 Mac 上不可用，只能手动" },
    ],
  },
  {
    title: "材料 → 知识",
    goal: "丢进一份材料 → 帮你消化、管理 → 形成自己的观点",
    usage: "截至 2026-09-23 提炼记录是 0。设置和本机命令这次已经做进代码，你正在用的 0.3.7 还没有这版",
    steps: [
      { name: "丢进材料", status: "partial", note: "网页 / PDF、截图 OCR、小红书、B 站、播客有专门处理；公众号仍是通用网页抽取，未验证。入口还是粘贴链接或选文件" },
      { name: "AI 消化", status: "partial", note: "设置里可选 MiniMax、DeepSeek、Kimi 或自定义地址，Key 进钥匙串，保存不发测试请求。Mac 还能改用已登录的 Codex 或 Claude，找不到命令就停，不悄悄改用云端。短材料用本机 Codex 提炼已通过证据校验。转写顺序是系统语音、SenseVoice，上传只在选了 MiniMax 时出现，Whisper 仍是 Mac 上单独打开的开关" },
      { name: "关联管理", status: "partial", note: "灵感可转笔记，笔记有单层分类；笔记之间不能互链，没有反向链接" },
      { name: "知识图谱", status: "missing", note: "没有" },
      { name: "形成观点", status: "missing", note: "不追问你的看法，也不跨材料综合" },
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
          依据：main 上这次的摘要设置、codex/jelly-ios 上的手机端、本机安装的 0.3.7，以及 2026-09-23 的数量统计（未读取内容）· 2026-09-29
        </Text>
      </Stack>

      <div style={{ padding: "16px 18px", borderRadius: 8, background: theme.fill.tertiary }}>
        <Stack gap={8}>
          <Text weight="semibold" style={{ fontSize: 16, lineHeight: 1.55 }}>
            摘要的模型可以选择了。灵感还是收不进来，也没有东西把它带回来。
          </Text>
          <Text tone="secondary" style={{ lineHeight: 1.6 }}>
            日历仍是唯一在用的部分。材料提炼现在可以选 MiniMax、DeepSeek、Kimi、自定义地址，Mac 上也可以改用已经登录的 Codex 或 Claude。纯文本灵感的延展、回头看、随手捕获都还没做。拆开并安排仍走 Apple 端侧模型，这台 Mac 上不可用。你正在用的安装包还是 0.3.7，要装上这次的版本，设置才会出现。
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
          <Finding title="摘要能选模型了，拆解还不能">
            <Text tone="secondary" style={{ lineHeight: 1.6 }}>
              摘要和转写读同一套设置。云端是预设加一把 Key；Mac 多一个“用这台机器上已登录的 Codex 或 Claude”。短材料走 Codex 已经能产出带原文证据的摘要。拆开并安排没有改，这台 M5 Pro 上仍是 deviceNotEligible。
            </Text>
            <Text size="small" tone="tertiary">
              DeepSeek 和 Kimi 只填好了地址和模型名，严格 JSON 只验证过 MiniMax-M3。
            </Text>
          </Finding>
          <Finding title="捕获离想法太远">
            <Text tone="secondary" style={{ lineHeight: 1.6 }}>
              灵感一半在手机、一半在 Mac，还想用语音。Mac 仍要窗口在前台并切到灵感页。手机有 App，但没有分享进来的入口，两台设备的数据也不相通。
            </Text>
          </Finding>
          <Finding title="能用的能力还没被用起来">
            <Text tone="secondary" style={{ lineHeight: 1.6 }}>
              来源抽取、转写路由、摘要合同都已经在代码里。你的日常数据里提炼仍是 0，安装包也还是 0.3.7。下一步不是再加来源，而是把这版装上，并让灵感在冒出来的地方就能收下。
            </Text>
          </Finding>
        </Grid>
      </Stack>

      <Divider />

      <Stack gap={14}>
        <Stack gap={4}>
          <H2>还没满足的，按离你目标的远近排</H2>
          <Text size="small" tone="tertiary">
            摘要设置从“当前必须”里拿掉了。剩下的是捕获、回头看，以及让延展和拆解去读这同一套设置。
          </Text>
        </Stack>
        <Grid columns={3} gap={28}>
          <GapColumn
            title="当前必须"
            hint="不做，灵感链路就转不起来"
            items={[
              {
                name: "Mac 上随手收下",
                why: "在任何 App 里按一个快捷键弹出小窗，回车就走，不用切到 Jelly",
              },
              {
                name: "手机上把东西丢进来",
                why: "App 已经有了，缺的是分享菜单或快捷指令。语音也可以走这条路。和 Mac 的同步仍未决定，先不要发明一套",
              },
              {
                name: "回头看",
                why: "固定节奏把没处理的灵感带回来，逐条三选一：留着 / 变成待办 / 丢掉。第一版可以不依赖 AI",
              },
              {
                name: "灵感延展",
                why: "收下后只补一句，再给 2–3 个方向，一键采纳或忽略，原文不改。模型读现在这套摘要设置",
              },
              {
                name: "手机提醒",
                why: "只把标了提醒的事项写进系统日历或提醒事项，靠 iCloud 在手机上响。和灵感链路互不依赖",
              },
            ]}
          />
          <GapColumn
            title="可以延后"
            hint="有价值，但不是现在的卡点"
            items={[
              { name: "把拆解改到同一套设置", why: "这台 Mac 上 Apple 智能不可用。摘要设置已经能给它用，这次故意没改行为" },
              { name: "无日期清单、自然语言快速添加", why: "你目前按天记录，暂时不卡" },
              { name: "灵感直接安排到某天", why: "跳过转笔记，等回顾节奏跑起来再做" },
              { name: "公众号正文抽取", why: "六类里唯一没专门处理的；通用抽取还没实测" },
              { name: "观点与跨材料综合", why: "前提是先有材料真的被提炼过" },
              { name: "Mac 与 iPhone 同步", why: "两端都有 App。同步方案还没选，不能先做" },
            ]}
          />
          <GapColumn
            title="应当收起或重新评估"
            hint="投入已超过它现在的价值"
            items={[
              {
                name: "“完成”相关的统计",
                why: "本周回顾里的完成 / 未完成 / 延期数，对不勾完成的你没有意义",
              },
              {
                name: "继续扩提炼来源",
                why: "六类基本都有了。重点改成把手机上的收藏送进来",
              },
              {
                name: "把 Whisper 当默认转写",
                why: "默认已是系统语音，然后 SenseVoice。Whisper 只在 Mac 上单独打开",
              },
              { name: "灵感 → 笔记 → 拆开 的两步路径", why: "对“一个想法变成一件事”来说太长，可以合并" },
            ]}
          />
        </Grid>
        <div style={{ padding: "12px 14px", borderRadius: 6, background: theme.fill.quaternary }}>
          <Stack gap={4}>
            <Text weight="semibold">现在的顺序</Text>
            <Text size="small" tone="secondary" style={{ lineHeight: 1.6 }}>
              摘要设置已经落地：云端预设加 Key，Mac 上可改用 Codex 或 Claude，界面跟日历同一套暖纸和陶土色。下一步是 Mac 快捷捕获和回头看，这两件不互相堵。灵感延展接已经做好的设置。手机提醒和“从别的 App 丢进来”可以并行验证，同步先不动。
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
              ["在滴答里依赖提醒吗", "依赖，主要靠手机", "提醒还没做。iOS App 有了，但没有通知"],
              ["灵感在哪儿冒出来", "手机和 Mac 差不多一半一半，也想用语音", "两端都能打开灵感页；都还不能从别的 App 收下"],
              ["最常收藏哪几类", "小红书、公众号、播客、B 站、网页、截图都有", "来源覆盖基本够。转写改为系统语音优先，其次 SenseVoice"],
              ["AI 用哪家", "用户自选，自带 Key", "摘要已做成预设加 Key，Mac 另加已登录的 Codex / Claude。拆解还没迁过来"],
            ]}
          />
        </CardBody>
      </Card>

      <CollapsibleSection title="代码与验证依据">
        <Table
          headers={["结论", "依据"]}
          rows={[
            ["摘要来源存在设置里", "DigestSettingsStore：service 为 minimax / deepseek / kimi / custom，另有 localRuntime codex / claude"],
            ["保存不发测试请求，留空不清 Key", "DigestSettingsView / MobileAIServices；检查进程保存 Kimi 后没有 TCP 连接，偏好写入独立套件"],
            ["找不到本机命令就停", "RoutingMaterialSummarizerTests：locate 返回空时抛 localRuntimeUnavailable，不调用命令"],
            ["本机 Codex 能产出可校验摘要", "2026-09-29 liveLocalCodexProducesGroundedV3Summary 通过，约 14 秒"],
            ["上传音频只在 MiniMax", "cloudSpeechUploadEnabled：来源是云端且服务是 MiniMax"],
            ["转写顺序", "TranscriptionRouting：系统语音，否则 SenseVoice；云端和 Whisper 都是回退开关"],
            ["拆解仍是 Apple 端侧", "这次没有改 Decomposition。本机此前探测为 unavailable(deviceNotEligible)"],
            ["手机有 App，没有本机命令", "codex/jelly-ios：同一套摘要预设；不提供 Codex / Claude，不下载 Whisper"],
            ["设置页用日历的表面", "JellySettingsChrome：暖纸底、选中块、陶土色保存。MCP 页同一套"],
            ["日常安装包还是 0.3.7", "本机 ~/Applications/Jelly.app 未替换。统计仍来自 2026-09-23 的数量，未重读内容"],
          ]}
        />
      </CollapsibleSection>
    </Stack>
  );
}
