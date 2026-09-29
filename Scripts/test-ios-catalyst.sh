#!/bin/bash
# Typecheck the whole iOS app (UIKit/SwiftUI views included) for an iOS 17
# target without Xcode's iOS SDK, by compiling as Mac Catalyst against the
# macOS SDK's iOSSupport. Catches iOS-only availability errors that
# Scripts/test-ios-shared.sh (plain macOS) cannot see.
#
# Not covered: files that need WhisperKit/FluidAudio (stubbed), code under
# `canImport(AppKit)` (treated as macOS-only, as on a real iPhone), and
# anything that differs between Catalyst and iPhone at runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SDK="$(xcrun --show-sdk-path)"
IOS="$SDK/System/iOSSupport"
TARGET="arm64-apple-ios17.0-macabi"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/jelly-ios-catalyst.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

common=(-target "$TARGET" -sdk "$SDK" -swift-version 6 -parse-as-library -I "$WORK/modules")
mkdir -p "$WORK/modules" "$WORK/patched"
for module in CalendarDomain WorkspaceDomain CalendarPersistence JellyMCP; do
    xcrun swiftc -emit-module -module-name "$module" "${common[@]}" \
        -emit-module-path "$WORK/modules/$module.swiftmodule" Sources/"$module"/*.swift
done

sources=()
while IFS= read -r file; do
    [ -n "$file" ] || continue
    if grep -q "^import WhisperKit\|^import FluidAudio" "$file"; then continue; fi
    if grep -q "canImport(AppKit)" "$file"; then
        # Catalyst can import AppKit, a real iPhone cannot.
        mkdir -p "$WORK/patched/$(dirname "$file")"
        sed 's/canImport(AppKit)/os(macOS)/' "$file" > "$WORK/patched/$file"
        sources+=("$WORK/patched/$file")
    else
        sources+=("$file")
    fi
done < <(grep -v '^#' iOS/shared-sources.txt | sed 's/[[:space:]]*$//'; ls iOS/Jelly/*.swift)

xcrun swiftc -typecheck "${common[@]}" \
    -Fsystem "$IOS/System/Library/Frameworks" -I "$IOS/usr/lib/swift" -Xcc -isystem -Xcc "$IOS/usr/include" \
    "${sources[@]}" Scripts/ios-catalyst-stubs/TranscriberStubs.swift

echo "PASS: ${#sources[@]} iOS app sources typechecked for $TARGET."
echo "UNVERIFIED: WhisperKit/SenseVoice transcribers, real iPhone SDK build, Simulator and device."
