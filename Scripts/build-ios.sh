#!/bin/bash
set -euo pipefail

usage() {
    cat <<'USAGE'
用法：Scripts/build-ios.sh [simulator|device] [Debug|Release]

默认构建 iOS 模拟器 Debug 版本；产物保存在 dist/ios/<配置>-<SDK>/Jelly.app。
需要完整 Xcode 26 或更新版本、Swift 6.2 和对应 iOS SDK。
脚本不修改 xcode-select，不配置签名团队，不安装到设备。
device 产物未签名；真机运行请在 Xcode 中选择自己的签名团队。
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi
if (( $# > 2 )); then
    usage >&2
    exit 64
fi

IOS_BUILD_PLATFORM="${1:-simulator}"
IOS_BUILD_CONFIGURATION="${2:-Debug}"
case "$IOS_BUILD_PLATFORM" in
    simulator)
        IOS_BUILD_SDK="iphonesimulator"
        IOS_BUILD_DESTINATION="generic/platform=iOS Simulator"
        ;;
    device)
        IOS_BUILD_SDK="iphoneos"
        IOS_BUILD_DESTINATION="generic/platform=iOS"
        ;;
    *) usage >&2; exit 64 ;;
esac
case "$IOS_BUILD_CONFIGURATION" in
    Debug|Release) ;;
    *) usage >&2; exit 64 ;;
esac

IOS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
IOS_REPO_DIR="$(cd "$IOS_SCRIPT_DIR/.." && pwd -P)"
IOS_PROJECT_PATH="$IOS_REPO_DIR/iOS/Jelly.xcodeproj"
IOS_OUTPUT_DIR="$IOS_REPO_DIR/dist/ios"

if ! /usr/bin/xcodebuild -version >/dev/null 2>&1; then
    cat >&2 <<'ERROR'
无法构建 iOS：当前未找到已启用的完整 Xcode。
Command Line Tools 不包含 iOS SDK。请先安装 Xcode 26 或更新版本，
打开 Xcode 完成组件安装，再用以下方式运行（无需改变系统默认路径）：
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/build-ios.sh
ERROR
    exit 69
fi
if ! /usr/bin/xcrun --sdk "$IOS_BUILD_SDK" --show-sdk-path >/dev/null 2>&1; then
    printf '无法构建 iOS：当前 Xcode 缺少 %s SDK，请在 Xcode Settings > Components 安装。\n' "$IOS_BUILD_SDK" >&2
    exit 69
fi
IOS_SWIFT_VERSION="$(/usr/bin/xcrun swiftc --version | /usr/bin/awk '/Swift version/ { for (i = 1; i < NF; i++) if ($i == "version") { print $(i+1); exit } }')"
if ! /usr/bin/awk -v version="$IOS_SWIFT_VERSION" 'BEGIN { split(version, v, "."); exit !(v[1] > 6 || (v[1] == 6 && v[2] >= 2)) }'; then
    printf '无法构建 iOS：共享 Package.swift 需要 Swift 6.2+，当前为 %s。\n' "${IOS_SWIFT_VERSION:-未知版本}" >&2
    exit 69
fi
if [[ ! -f "$IOS_PROJECT_PATH/project.pbxproj" ]]; then
    printf '找不到 Xcode 工程：%s\n' "$IOS_PROJECT_PATH" >&2
    exit 66
fi

mkdir -p "$IOS_OUTPUT_DIR"
/usr/bin/xcodebuild \
    -project "$IOS_PROJECT_PATH" \
    -scheme Jelly-iOS \
    -configuration "$IOS_BUILD_CONFIGURATION" \
    -sdk "$IOS_BUILD_SDK" \
    -destination "$IOS_BUILD_DESTINATION" \
    -derivedDataPath "$IOS_OUTPUT_DIR/DerivedData" \
    CONFIGURATION_BUILD_DIR="$IOS_OUTPUT_DIR/$IOS_BUILD_CONFIGURATION-$IOS_BUILD_SDK" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

IOS_APP_PATH="$IOS_OUTPUT_DIR/$IOS_BUILD_CONFIGURATION-$IOS_BUILD_SDK/Jelly.app"
if [[ ! -f "$IOS_APP_PATH/Info.plist" || ! -x "$IOS_APP_PATH/Jelly" ]]; then
    printf 'Xcode 返回成功，但未找到预期 App 产物：%s\n' "$IOS_APP_PATH" >&2
    exit 70
fi
/usr/bin/plutil -lint "$IOS_APP_PATH/Info.plist"
printf '\n构建完成（未签名）：%s\n' "$IOS_APP_PATH"
