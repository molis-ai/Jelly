#!/bin/bash
set -euo pipefail
if [[ $# != 1 || "$1" == "--help" ]]; then
    printf '用法：Scripts/test-ios-ui.sh <专用 iPhone 模拟器 UDID>\n用例创建独立命名的样例数据，验证三模块操作和重启；不会删除已有数据。\n'
    exit 64
fi
IOS_TEST_DEVICE="$1"
IOS_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
IOS_TEST_DERIVED="$IOS_TEST_ROOT/dist/ios/DerivedData"
IOS_TEST_OUTPUT="$IOS_TEST_ROOT/dist/ios/validation/ui-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$IOS_TEST_OUTPUT"
printf 'UI 验证输出：%s\n' "$IOS_TEST_OUTPUT"
/usr/bin/xcodebuild -project "$IOS_TEST_ROOT/iOS/Jelly.xcodeproj" -scheme Jelly-iOS \
    -destination "platform=iOS Simulator,id=$IOS_TEST_DEVICE" \
    -derivedDataPath "$IOS_TEST_DERIVED" \
    CONFIGURATION_BUILD_DIR="$IOS_TEST_ROOT/dist/ios/Debug-iphonesimulator" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build-for-testing \
    > "$IOS_TEST_OUTPUT/build.log" 2>&1
IOS_TEST_SDK="$(/usr/bin/xcrun --sdk iphonesimulator --show-sdk-version)"
IOS_TEST_RUN="$IOS_TEST_DERIVED/Build/Products/Jelly-iOS_iphonesimulator${IOS_TEST_SDK}-$(uname -m).xctestrun"
if [[ ! -f "$IOS_TEST_RUN" ]]; then
    printf '未找到 Xcode 测试描述文件：%s\n请查看 %s/build.log\n' "$IOS_TEST_RUN" "$IOS_TEST_OUTPUT" >&2
    exit 66
fi
/usr/bin/xcodebuild -xctestrun "$IOS_TEST_RUN" \
    -destination "platform=iOS Simulator,id=$IOS_TEST_DEVICE" \
    -resultBundlePath "$IOS_TEST_OUTPUT/journey.xcresult" \
    -parallel-testing-enabled NO -collect-test-diagnostics never test-without-building \
    > "$IOS_TEST_OUTPUT/test.log" 2>&1
printf 'UI 测试通过。日志与截图结果：%s\n' "$IOS_TEST_OUTPUT"
