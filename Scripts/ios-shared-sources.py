#!/usr/bin/env python3
"""Keep iOS/shared-sources.txt and the Xcode project's explicit shared-source
references in step.

  Scripts/ios-shared-sources.py add Sources/CalendarApp/Foo/Bar.swift [...]
  Scripts/ios-shared-sources.py check

`add` appends to the manifest and inserts a PBXFileReference, a PBXBuildFile,
a "Shared Sources" group child and a Sources build-phase entry, mirroring the
hand-written entries already in the project. `check` fails when the manifest
and the project disagree. Neither command touches signing or targets.
"""
import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "iOS/shared-sources.txt"
PROJECT = ROOT / "iOS/Jelly.xcodeproj/project.pbxproj"


def manifest_entries():
    return [
        line.strip()
        for line in MANIFEST.read_text().splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def project_paths(text):
    return set(re.findall(r'path = "\.\./(Sources/[^"]+\.swift)";', text))


def built_names(text):
    phase = re.search(r"isa = \"PBXSourcesBuildPhase\";", text)
    return set(re.findall(r"/\* ([^*]+\.swift) in Sources \*/,", text))


def make_id(seed):
    return hashlib.sha1(seed.encode()).hexdigest()[:24].upper()


def add(paths):
    text = PROJECT.read_text()
    manifest = MANIFEST.read_text()
    existing = project_paths(text)
    for relative in paths:
        relative = relative.strip().lstrip("./")
        if not (ROOT / relative).is_file():
            raise SystemExit(f"missing source: {relative}")
        name = pathlib.Path(relative).name
        if relative in existing:
            print(f"already referenced: {relative}")
            continue
        file_id = make_id("file:" + relative)
        build_id = make_id("build:" + relative)
        if file_id in text or build_id in text:
            raise SystemExit(f"id collision for {relative}")
        file_ref = (
            f"\t\t{file_id} /* {name} */ = {{\n"
            f"\t\t\tisa = \"PBXFileReference\";\n"
            f"\t\t\tlastKnownFileType = \"sourcecode.swift\";\n"
            f"\t\t\tname = \"{name}\";\n"
            f"\t\t\tpath = \"../{relative}\";\n"
            f"\t\t\tsourceTree = \"SOURCE_ROOT\";\n"
            f"\t\t}};\n"
            f"\t\t{build_id} /* {name} in Sources */ = {{\n"
            f"\t\t\tfileRef = {file_id} /* {name} */;\n"
            f"\t\t\tisa = \"PBXBuildFile\";\n"
            f"\t\t}};\n"
        )
        anchor = "\t\tE88E88E88E88E88E88E88E88 /* RoutingMaterialSummarizer.swift */ = {\n"
        if anchor not in text:
            raise SystemExit("anchor file reference not found")
        text = text.replace(anchor, file_ref + anchor, 1)
        group_anchor = "\t\t\t\tE88E88E88E88E88E88E88E88 /* RoutingMaterialSummarizer.swift */,\n"
        text = text.replace(group_anchor, group_anchor + f"\t\t\t\t{file_id} /* {name} */,\n", 1)
        phase_anchor = "\t\t\t\tF99F99F99F99F99F99F99F99 /* RoutingMaterialSummarizer.swift in Sources */,\n"
        text = text.replace(phase_anchor, phase_anchor + f"\t\t\t\t{build_id} /* {name} in Sources */,\n", 1)
        if relative not in manifest_entries():
            if not manifest.endswith("\n"):
                manifest += "\n"
            manifest += relative + "\n"
        existing.add(relative)
        print(f"added: {relative}")
    PROJECT.write_text(text)
    MANIFEST.write_text(manifest)


def check():
    text = PROJECT.read_text()
    manifest = set(manifest_entries())
    referenced = project_paths(text)
    built = built_names(text)
    problems = []
    for path in sorted(manifest - referenced):
        problems.append(f"in manifest but not in project: {path}")
    for path in sorted(referenced - manifest):
        problems.append(f"in project but not in manifest: {path}")
    for path in sorted(manifest):
        if pathlib.Path(path).name not in built:
            problems.append(f"not in Sources build phase: {path}")
    if problems:
        raise SystemExit("\n".join(problems))
    print(f"OK: {len(manifest)} shared sources referenced and built")


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "check":
        check()
    elif len(sys.argv) >= 3 and sys.argv[1] == "add":
        add(sys.argv[2:])
        check()
    else:
        raise SystemExit(__doc__)
