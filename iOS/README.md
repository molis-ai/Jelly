# Jelly iOS

这是 Jelly 的原生 iPhone / iPad 工程，最低系统为 iOS 17。移动端界面位于 `Jelly/`，核心日历、工作空间与持久化继续使用仓库根目录的 Swift Package；平台无关的桌面应用服务以原文件引用方式编译，清单见 `shared-sources.txt`。

**已有通过真实 iOS SDK 编译的模拟器 App，完整开发与验收尚未完成。** 当前源码进度、完整功能差距与已执行的证据分别见[功能对照与验收](../docs/ios/功能对照与验收.md)和[验证记录](../docs/ios/验证记录.md)。已在 iPhone 17 模拟器启动；日历、笔记、文字灵感的基础操作与重启验证已通过，不能当作已通过完整 iOS 验收的 App。

## 开发环境

- macOS 与完整 Xcode 26 或更新版本。根目录 `Package.swift` 使用 Swift 6.2。
- 对应的 iOS SDK；在模拟器中运行还需要安装 iOS Simulator Runtime。
- 首次解析 Swift Package 依赖需要网络。`CalendarDomain`、`WorkspaceDomain`、`CalendarPersistence`、`JellyMCP` 是本地依赖，`WhisperKit` 沿用桌面端的 1.0.0 版本。

2026-09-27 已安装 Xcode 27.0（27A266a）及 iOS 27.0 Simulator（24A434）；用户处理许可后，真实 Debug 模拟器构建通过。产物包含 arm64 与 x86_64，已安装到 iPhone 17 并显示日历首屏与事项表单。最终测试产物为 arm64；真机签名、全功能操作与用户验收仍未完成。

共享源码、移动服务和移动 AI 视图已使用本机 macOS SDK 做实际 Swift 类型检查；持久化闭环由 `Scripts/test-ios-shared.sh` 验证。这些检查不覆盖 iOS SDK API、iOS 布局或触摸交互。

## 在 Xcode 运行

1. 打开 `iOS/Jelly.xcodeproj`。
2. 选择共享 Scheme `Jelly-iOS` 与一个 iPhone 或 iPad 模拟器。
3. 等待本地 Swift Package 与远程依赖解析完成，按 Run。
4. 真机运行时，在 Target `Jelly` 的 Signing & Capabilities 中选择自己的 Team。工程没有预设开发者团队或证书。

仓库直接保存 `.xcodeproj`，无需 XcodeGen 或 Ruby 依赖。`Jelly/` 是 Xcode 的文件系统同步源码组，新增 Swift 文件会自动加入目标；桌面共享文件在工程中明确引用，不复制源码。修改 `shared-sources.txt` 后须同步更新工程的 Shared Sources 引用与 Sources 构建阶段。

## 命令行构建

在仓库根目录运行：

```sh
Scripts/build-ios.sh
Scripts/build-ios.sh simulator Release
Scripts/build-ios.sh device Release
```

如果当前选中的是 Command Line Tools，可为单次命令指定 Xcode：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/build-ios.sh
```

脚本先检查完整 Xcode、目标 SDK 与 Swift 版本。产物保存在 `dist/ios/Debug-iphonesimulator/Jelly.app` 等独立目录，DerivedData 位于 `dist/ios/DerivedData`。脚本不会修改系统 Xcode 选择、配置签名、自动安装、上传或发布；`device` 产物没有签名，不能直接作为可安装的发行包。

## 工程约定与验收

- Bundle ID：`com.oreal.jelly.ios`；显示名称：Jelly。
- App Icon 原样复用 `Support/AppIcon.png`；AccentColor 的浅色 `#A55D3B`、深色 `#D68D68` 来自桌面 `CalendarTheme`。
- iOS 和 macOS 的 App 沙箱各自独立。共享数据模型与文件格式不表示跨设备自动同步已经实现。
- `MobileAIServices` 初始化不发送网络请求。材料提炼、Apple 智能拆解与 Whisper 模型下载分别由用户点按启动，模型下载保留大小说明和确认；摘要密钥使用系统钥匙串。隔离验证设置 `JELLY_ACCEPTANCE_DATA_DIRECTORY`，沿用桌面服务的独立配置与凭据命名空间。
- 需要实际验证：iPhone / iPad 布局、深浅色与动态字体、手势与键盘、中文输入法、编辑保存后重启、导入导出、失败与恢复。只有执行过的具体路径才能记录为产品实操通过。
- 模拟器构建通过与真机签名安装、产品实操、用户本人验收是不同证据，不相互替代。

## 已跑通的模拟器验证

2026-09-27，`JellyJourneyTests.testCalendarNotesAndInspirationSurviveRelaunch` 在 iPhone 17 / iOS 27.0 通过：日历创建、完成、重启后重开；笔记输入标题正文、返回保存、重新打开及重启重读；文字灵感捕获、转笔记、重启后来源关联保留。主 Agent 已查看四张实际截图并独立核对沙盒 JSON。未调用真实 AI、未使用真机，此结论只覆盖基础旅程。

```sh
# 选择专用模拟器，避免与手动试用相互干扰；不删除旧样例数据。
xcrun simctl list devices available
# 将下面的 YOUR_SIMULATOR_UDID 替换为本机专用 iPhone 模拟器的 UDID。
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/test-ios-ui.sh YOUR_SIMULATOR_UDID
```

原始日志、xcresult、截图与沙盒核对文件只保留在本地，不随 Git 分发；新 checkout 可用上面的脚本生成自己的结果。最终本地证据：`dist/ios/validation/ui-20260927-204034/`。可见试用设备是 `iPhone 17`（`A7C13740-8843-48C7-A223-DBDBB6096E67`），其中运行的 App 与测试产物二进制 SHA-256 相同。专用测试设备名为 `Jelly UI Validation`。
