#!/bin/zsh
# Runs every CalendarAppTests suite in its own `swift test` process.
#
# A single `swift test` over the app target can stop part-way with exit
# status 0 and no summary (seen on main as well), so its output cannot be
# trusted as a full result. One process per suite makes every suite report.
#
#   Scripts/test-app-suites.sh [output-dir]
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
OUT=${1:-$(mktemp -d "${TMPDIR:-/tmp}/jelly-app-suites.XXXXXX")}
mkdir -p "$OUT"
cd "$ROOT"

swift build --build-tests >/dev/null 2>&1 || { echo "build failed" >&2; exit 2; }

suites=$(python3 - <<'PY'
import glob, re
names = set()
for path in sorted(glob.glob("Tests/CalendarAppTests/*.swift")):
    lines = open(path, encoding="utf-8").read().splitlines()
    for index, line in enumerate(lines):
        if line.strip().startswith("@Suite"):
            for follow in lines[index + 1:index + 5]:
                match = re.match(r"\s*(?:@MainActor\s+)?(?:final\s+)?(?:struct|class|enum)\s+(\w+)", follow)
                if match:
                    names.add(match.group(1))
                    break
print("\n".join(sorted(names)))
PY
)

passed=0; failed=0; silent=0
: > "$OUT/summary.txt"
for suite in ${(f)suites}; do
  log="$OUT/$suite.log"
  swift test --skip-build --filter "CalendarAppTests\\.$suite/" > "$log" 2>&1
  line=$(grep -E "Test run with" "$log" | tail -1)
  if [[ -z "$line" ]]; then
    silent=$((silent + 1)); echo "NO SUMMARY  $suite" >> "$OUT/summary.txt"
  elif [[ "$line" == *passed* ]]; then
    passed=$((passed + 1)); echo "PASS        $suite  ${line#*Test run with }" >> "$OUT/summary.txt"
  else
    failed=$((failed + 1)); echo "FAIL        $suite  ${line#*Test run with }" >> "$OUT/summary.txt"
    grep -E "✘ Test .* failed after" "$log" | sed 's/ after.*//; s/^/              /' >> "$OUT/summary.txt"
  fi
done
echo "suites passed=$passed failed=$failed no-summary=$silent  (logs: $OUT)" | tee -a "$OUT/summary.txt"
