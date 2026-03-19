#!/bin/bash
set -euo pipefail

DATA_FILE="docs/data.json"
TEST_ROOT="tests"
RESULT_FILE="test-results/results.json"
SAFE_RESULT_FILE="/tmp/playwright-results.json"

DATE=$(date +"%Y-%m-%d")

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr -d '\n')
if [ "$BRANCH" = "HEAD" ] || [ -z "$BRANCH" ]; then
  BRANCH="local"
fi

COMMIT=$(git rev-parse --short HEAD 2>/dev/null | tr -d '\n')
if [ -z "$COMMIT" ]; then
  COMMIT="local"
fi

# Run context
RUN_TYPE="${RUN_TYPE:-full}"
RUN_REASON="${RUN_REASON:-regular}"
RUN_LABEL="${RUN_LABEL:-Standard Regression}"
RUN_FILTER="${RUN_FILTER:-all}"

FULL_REGRESSION_EXECUTED=true
PY_FULL_REGRESSION_EXECUTED="True"

if [[ "$RUN_TYPE" != "full" ]]; then
  FULL_REGRESSION_EXECUTED=false
  PY_FULL_REGRESSION_EXECUTED="False"
fi

# Persist rules (can be overridden via env var PERSIST_METRICS)
PERSIST_METRICS=${PERSIST_METRICS:-false}
if [[ "$BRANCH" == "master" || "$BRANCH" == feature* ]]; then
  PERSIST_METRICS=true
fi

echo "Collecting Playwright test stats..."

# Preserve the latest full-test results.json while we use Playwright's --list mode.
# The --list run can overwrite the configured json reporter output, so we back it up.
rm -f "$SAFE_RESULT_FILE"
if [ -f "$RESULT_FILE" ]; then
  cp "$RESULT_FILE" "$SAFE_RESULT_FILE"
fi

PLAYWRIGHT_LIST=$(npx playwright test --list --reporter=list 2>/dev/null || true)

# Restore the real result file if it was overwritten.
if [ -f "$SAFE_RESULT_FILE" ]; then
  mv "$SAFE_RESULT_FILE" "$RESULT_FILE"
else
  rm -f "$RESULT_FILE"
fi

calc_health() {
  local active=$1
  local total=$2
  if [ "$total" -eq 0 ]; then echo 0; else echo $((active * 100 / total)); fi
}

calc_rate() {
  local value=$1
  local total=$2
  if [ "$total" -eq 0 ]; then echo 0; else echo $((value * 100 / total)); fi
}

# Toplam test sayısı
TOTAL=$(printf '%s\n' "$PLAYWRIGHT_LIST" | grep -cE '^\s+[^ ]' || true)
TOTAL=${TOTAL:-0}

FIXME=$(grep -rhoE 'test\.fixme|test\.describe\.fixme' "$TEST_ROOT"/ 2>/dev/null | wc -l | tr -d ' ' || true)
SKIPPED=$(grep -rhoE 'test\.skip|test\.describe\.skip' "$TEST_ROOT"/ 2>/dev/null | wc -l | tr -d ' ' || true)
FIXME=${FIXME:-0}
SKIPPED=${SKIPPED:-0}

ACTIVE=$((TOTAL - FIXME - SKIPPED))
if [ "$ACTIVE" -lt 0 ]; then ACTIVE=0; fi

OVERALL_HEALTH=$(calc_health "$ACTIVE" "$TOTAL")

# Global execution metrics (based on the most recent full test run)
if [ -f "$RESULT_FILE" ]; then
  EXEC_STATS=$(jq '
    [.. | objects | select(has("status") and has("results") and
      (.status == "expected" or .status == "unexpected" or .status == "skipped"))]
    | group_by(.status)
    | map({(.[0].status): length})
    | add
    | {
        passed: (.expected // 0),
        failed: (.unexpected // 0),
        skipped: (.skipped // 0)
      }
  ' "$RESULT_FILE")
  PASSED=$(echo "$EXEC_STATS" | jq '.passed')
  FAILED=$(echo "$EXEC_STATS" | jq '.failed')
  EXEC_SKIPPED=$(echo "$EXEC_STATS" | jq '.skipped')
else
  PASSED=0
  FAILED=0
  EXEC_SKIPPED=0
fi

EXEC_TOTAL=$((PASSED + FAILED + EXEC_SKIPPED))
PASS_RATE=$(calc_rate "$PASSED" "$EXEC_TOTAL")
FAIL_RATE=$(calc_rate "$FAILED" "$EXEC_TOTAL")

echo "Total:           $TOTAL"
echo "Active:          $ACTIVE"
echo "Fixme:           $FIXME"
echo "Skipped:         $SKIPPED"
echo "Health:          ${OVERALL_HEALTH}%"
echo "-----------------------------"
echo "Execution total: $EXEC_TOTAL"
echo "Passed:          $PASSED"
echo "Failed:          $FAILED"
echo "Exec skipped:    $EXEC_SKIPPED"
echo "Pass rate:       ${PASS_RATE}%"
echo "Fail rate:       ${FAIL_RATE}%"
echo "-----------------------------"
echo "Run type:        $RUN_TYPE"
echo "Run reason:      $RUN_REASON"
echo "Run label:       $RUN_LABEL"
echo "Run filter:      $RUN_FILTER"
echo "Full regression: $FULL_REGRESSION_EXECUTED"
echo "Date:            $DATE"
echo "Branch:          $BRANCH"
echo "Commit:          $COMMIT"
echo "Persist:         $PERSIST_METRICS"

mkdir -p docs

FILES_JSON="["
FIRST_FILE=1
BY_MODULE_JSON="{"
FIRST_MOD=1

# Modüller: tests/ altındaki klasörler (api, web, mobile, desktop ...)
MODULES=$(find "$TEST_ROOT" -mindepth 1 -maxdepth 1 -type d | sed "s|^${TEST_ROOT}/||" | sort)

for MODULE in $MODULES; do
  MOD_DIR="${TEST_ROOT}/${MODULE}"
  MOD_TOTAL=0
  MOD_ACTIVE=0
  MOD_FIXME=0
  MOD_SKIPPED=0

  # Modül bazlı execution — results.json suite title'larından çıkar
  # Suite title formatı: "api/auth.spec.ts" → modül = "api"
  if [ -f "$SAFE_RESULT_FILE" ]; then
    MOD_EXEC=$(jq --arg mod "$MODULE" '
      [
        .suites[]
        | select(.title | startswith($mod + "/"))
        | .. | objects
        | select(has("status") and has("results") and
            (.status == "expected" or .status == "unexpected" or .status == "skipped"))
      ]
      | group_by(.status)
      | map({(.[0].status): length})
      | add // {}
      | {
          passed: (.expected // 0),
          failed: (.unexpected // 0),
          skipped: (.skipped // 0)
        }
    ' "$SAFE_RESULT_FILE")
    MOD_PASSED=$(echo "$MOD_EXEC" | jq '.passed')
    MOD_FAILED=$(echo "$MOD_EXEC" | jq '.failed')
    MOD_EXEC_SKIPPED=$(echo "$MOD_EXEC" | jq '.skipped')
  else
    MOD_PASSED=0
    MOD_FAILED=0
    MOD_EXEC_SKIPPED=0
  fi

  while IFS= read -r SPEC_FILE; do
    BASENAME=$(basename "$SPEC_FILE")

    COUNT=$(printf '%s\n' "$PLAYWRIGHT_LIST" | grep -c "$BASENAME" || true)
    COUNT=${COUNT:-0}

    FILE_FIXME=$(grep -hoE 'test\.fixme|test\.describe\.fixme' "$SPEC_FILE" 2>/dev/null | wc -l | tr -d ' ' || true)
    FILE_SKIPPED=$(grep -hoE 'test\.skip|test\.describe\.skip' "$SPEC_FILE" 2>/dev/null | wc -l | tr -d ' ' || true)
    FILE_FIXME=${FILE_FIXME:-0}
    FILE_SKIPPED=${FILE_SKIPPED:-0}

    FILE_ACTIVE=$((COUNT - FILE_FIXME - FILE_SKIPPED))
    if [ "$FILE_ACTIVE" -lt 0 ]; then FILE_ACTIVE=0; fi

    FILE_HEALTH=$(calc_health "$FILE_ACTIVE" "$COUNT")

    MOD_TOTAL=$((MOD_TOTAL + COUNT))
    MOD_ACTIVE=$((MOD_ACTIVE + FILE_ACTIVE))
    MOD_FIXME=$((MOD_FIXME + FILE_FIXME))
    MOD_SKIPPED=$((MOD_SKIPPED + FILE_SKIPPED))

    if [ "$FIRST_FILE" -eq 1 ]; then FIRST_FILE=0; else FILES_JSON="$FILES_JSON,"; fi
    FILES_JSON="${FILES_JSON}{\"name\":\"${BASENAME}\",\"path\":\"${SPEC_FILE}\",\"module\":\"${MODULE}\",\"total\":${COUNT},\"active\":${FILE_ACTIVE},\"fixme\":${FILE_FIXME},\"skipped\":${FILE_SKIPPED},\"health\":${FILE_HEALTH}}"

  done < <(find "$MOD_DIR" -name "*.spec.ts" | sort)

  MOD_HEALTH=$(calc_health "$MOD_ACTIVE" "$MOD_TOTAL")
  MOD_EXEC_TOTAL=$((MOD_PASSED + MOD_FAILED + MOD_EXEC_SKIPPED))
  MOD_PASS_RATE=$(calc_rate "$MOD_PASSED" "$MOD_EXEC_TOTAL")
  MOD_FAIL_RATE=$(calc_rate "$MOD_FAILED" "$MOD_EXEC_TOTAL")

  if [ "$FIRST_MOD" -eq 1 ]; then FIRST_MOD=0; else BY_MODULE_JSON="${BY_MODULE_JSON},"; fi
  BY_MODULE_JSON="${BY_MODULE_JSON}\"${MODULE}\":{\"total\":${MOD_TOTAL},\"active\":${MOD_ACTIVE},\"fixme\":${MOD_FIXME},\"skipped\":${MOD_SKIPPED},\"health\":${MOD_HEALTH},\"execution\":{\"passed\":${MOD_PASSED},\"failed\":${MOD_FAILED},\"skipped\":${MOD_EXEC_SKIPPED},\"passRate\":${MOD_PASS_RATE},\"failRate\":${MOD_FAIL_RATE}}}"

done

FILES_JSON="${FILES_JSON}]"
BY_MODULE_JSON="${BY_MODULE_JSON}}"

echo "By module: $BY_MODULE_JSON"
echo "Files: $FILES_JSON"

if [ "$PERSIST_METRICS" != "true" ]; then
  echo "Skipping docs/data.json update for branch: $BRANCH"
  exit 0
fi

python3 - <<EOF
import json
from pathlib import Path

DATA_FILE = "$DATA_FILE"
RESULT_FILE = "$RESULT_FILE"

# Build module-level summaries from file info.
files = json.loads("""$FILES_JSON""")
by_module = {}
for f in files:
    module = f.get("module", "root")
    entry = by_module.setdefault(module, {"total": 0, "active": 0, "fixme": 0, "skipped": 0, "health": 0})
    entry["total"] += f.get("total", 0)
    entry["active"] += f.get("active", 0)
    entry["fixme"] += f.get("fixme", 0)
    entry["skipped"] += f.get("skipped", 0)

# Compute a simple health score (ratio of active to total) for each module.
for module, entry in by_module.items():
    total = entry.get("total", 0)
    active = entry.get("active", 0)
    entry["health"] = int(active * 100 / total) if total else 0

# Derive execution stats per module from Playwright results.json (if present).
module_execution = {}
if Path(RESULT_FILE).is_file():
    try:
        results = json.load(open(RESULT_FILE))

        def walk_suites(suite, file_path=None):
            file_path = suite.get("file") or file_path
            for spec in suite.get("specs", []):
                for test in spec.get("tests", []):
                    status = test.get("status")
                    if status is None:
                        continue
                    module = (file_path or "").split("/")[0] or "root"
                    exec_entry = module_execution.setdefault(module, {"passed": 0, "failed": 0, "skipped": 0})
                    if status == "expected":
                        exec_entry["passed"] += 1
                    elif status == "unexpected":
                        exec_entry["failed"] += 1
                    elif status == "skipped":
                        exec_entry["skipped"] += 1
            for child in suite.get("suites", []):
                walk_suites(child, file_path)

        for top in results.get("suites", []):
            walk_suites(top)
    except Exception:
        module_execution = {}

for module, stats in module_execution.items():
    total = stats.get("passed", 0) + stats.get("failed", 0) + stats.get("skipped", 0)
    pass_rate = int(stats.get("passed", 0) * 100 / total) if total else 0
    fail_rate = int(stats.get("failed", 0) * 100 / total) if total else 0
    module_entry = by_module.setdefault(module, {"total": 0, "active": 0, "fixme": 0, "skipped": 0, "health": 0})
    module_entry["execution"] = {
        "passed": stats.get("passed", 0),
        "failed": stats.get("failed", 0),
        "skipped": stats.get("skipped", 0),
        "passRate": pass_rate,
        "failRate": fail_rate
    }

new_entry = {
  "date": "$DATE",
  "commit": "$COMMIT",
  "branch": "$BRANCH",
  "runContext": {
    "type": "$RUN_TYPE",
    "reason": "$RUN_REASON",
    "label": "$RUN_LABEL",
    "filter": "$RUN_FILTER",
    "fullRegressionExecuted": $PY_FULL_REGRESSION_EXECUTED
  },
  "summary": {
    "total": $TOTAL,
    "active": $ACTIVE,
    "fixme": $FIXME,
    "skipped": $SKIPPED,
    "health": $OVERALL_HEALTH
  },
  "execution": {
    "total": $EXEC_TOTAL,
    "passed": $PASSED,
    "failed": $FAILED,
    "skipped": $EXEC_SKIPPED,
    "passRate": $PASS_RATE,
    "failRate": $FAIL_RATE
  },
  "byModule": by_module,
  "files": files
}

try:
    with open(DATA_FILE) as f:
        existing = json.load(f)
except Exception:
    existing = {"project": "test-insight", "history": []}

history = existing.get("history", [])

history = [
    h for h in history
    if not (
        h.get("date") == new_entry["date"]
        and h.get("commit") == new_entry["commit"]
        and h.get("runContext", {}).get("type") == new_entry["runContext"]["type"]
    )
]

last_entry = history[-1] if history else None

def comparable_payload(entry):
    return {
        "runContext": entry.get("runContext"),
        "summary": entry.get("summary"),
        "byModule": entry.get("byModule"),
        "files": entry.get("files"),
    }

if last_entry is None or comparable_payload(last_entry) != comparable_payload(new_entry):
    history.append(new_entry)
    history = history[-6:]
else:
    print("No meaningful inventory change detected, skipping history append.")

result = {
    "project": existing.get("project", "test-insight"),
    "last_updated": new_entry["date"],
    "current": new_entry,
    "history": history
}

with open(DATA_FILE, "w") as f:
    json.dump(result, f, indent=2)

print("Saved to", DATA_FILE)
EOF

echo "Metrics written to docs/data.json"