#!/bin/bash
# Validate the production mobile data/services path on macOS without an iOS SDK.
# This does not build the iOS app or exercise UIKit/SwiftUI on a device.
set -euo pipefail

TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"

# The manifest and the Xcode project's explicit references must agree.
python3 Scripts/ios-shared-sources.py check

# Build the real dependencies, including WhisperKit used by mobile AI services.
# The generated executable's link list is the authoritative dependency closure.
swift build --product PersonalCalendar
TASK_BIN_PATH="$(swift build --show-bin-path)"

python3 - "$TASK_ROOT" "$TASK_BIN_PATH" <<'PY'
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
bin_path = Path(sys.argv[2])
manifest = root / "iOS/shared-sources.txt"
shared = [
    root / line.strip()
    for line in manifest.read_text().splitlines()
    if line.strip() and not line.lstrip().startswith("#")
]
if len(shared) != len(set(shared)):
    raise SystemExit("shared-sources.txt contains duplicate sources")
missing = [str(path) for path in shared if not path.is_file()]
if missing:
    raise SystemExit("Missing shared sources: " + ", ".join(missing))

sources = shared + [root / "iOS/Jelly/MobileWorkspace.swift"]
sources.append(root / "iOS/Jelly/MobileAIServices.swift")
sources.append(root / "iOS/Jelly/MobileItemEditing.swift")
sources.append(root / "iOS/Jelly/MobileTimeGrid.swift")
sources.append(root / "iOS/Jelly/MobileNoteSession.swift")
sources.append(root / "iOS/Jelly/MobileDocumentTextMap.swift")

common = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-I", str(bin_path / "Modules")]
# FluidAudio (SenseVoice) re-exports C modules; point clang at their module maps.
module_maps = sorted((root / ".build/checkouts/FluidAudio/Sources").glob("*/include/module.modulemap"))
module_maps += sorted((root / ".build/artifacts").glob("**/macos-*/Headers/*/module.modulemap"))
for module_map in module_maps:
    common += ["-Xcc", f"-fmodule-map-file={module_map}", "-Xcc", f"-I{module_map.parent}"]
typecheck_sources = sources + [root / "iOS/Jelly/MobileAIViews.swift", root / "iOS/Jelly/MobileMonthStream.swift"]
typecheck_sources += [root / "iOS/Jelly/MobileReminders.swift", root / "iOS/Jelly/JellyIntents.swift", root / "iOS/Jelly/MobileFollowUp.swift", root / "iOS/Jelly/MobileUndatedListView.swift"]
subprocess.run(common + ["-typecheck"] + [str(path) for path in typecheck_sources], check=True, cwd=root)

link_list = bin_path / "PersonalCalendar.product/Objects.LinkFileList"
objects = [
    line.strip()
    for line in link_list.read_text().splitlines()
    if line.strip() and "/CalendarApp.build/" not in line
]
if not objects:
    raise SystemExit("The desktop product's dependency link list is empty")

with tempfile.TemporaryDirectory(prefix="jelly-mobile-shared-validation-") as temporary:
    executable = Path(temporary) / "MobileWorkspaceSmoke"
    command = common + ["-o", str(executable)]
    command += [str(path) for path in sources]
    command += [str(root / "iOS/Validation/MobileWorkspaceSmoke.swift"), str(root / "iOS/Validation/MobileItemEditingSmoke.swift"), str(root / "iOS/Validation/MobileNoteSessionSmoke.swift")]
    command += objects
    command += [str(path) for path in sorted((root / ".build/artifacts").glob("**/macos-*/*.a"))]
    command += ["-lc++", "-framework", "Security", "-framework", "AVFoundation", "-framework", "Vision", "-framework", "PDFKit", "-framework", "Speech", "-framework", "CoreML", "-framework", "Accelerate"]
    subprocess.run(command, check=True, cwd=root)
    environment = dict(os.environ)
    environment["JELLY_ACCEPTANCE_DATA_DIRECTORY"] = str(Path(temporary) / "isolated-configuration")
    subprocess.run([str(executable)], check=True, cwd=root, env=environment, timeout=120)

print(f"PASS: {len(shared)} shared source files typechecked; mobile persistence/service smoke passed on macOS.")
print("UNVERIFIED: iOS SDK build, Simulator, device, UI interaction and live AI providers.")
PY
