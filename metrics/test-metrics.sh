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

# Persist rules
PERSIST_METRICS=${PERSIST_METRICS:-false}
if [[ "$BRANCH" == "master" || "$BRANCH" == feature* ]]; then
  PERSIST_METRICS=true
fi

echo "Collecting Playwright test stats..."

rm -f "$SAFE_RESULT_FILE"
if [ -f "$RESULT_FILE" ]; then
  cp "$RESULT_FILE" "$SAFE_RESULT_FILE"
fi

PLAYWRIGHT_LIST=$(npx playwright test --list --reporter=list 2>/dev/null || true)

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

# ---------------------------------------------------------------------------
# Test sayma fonksiyonu — tek yerde tanımla, hem current hem baseline'da kullan
#
# Kurallar:
#   TOTAL   = test('['\"]  +  test.skip('['\"]  +  test.fixme('['\"]  +  test.only('['\"]
#   SKIPPED = test.skip('['\"]  +  test.describe.skip(
#   FIXME   = test.fixme('['\"]  +  test.describe.fixme(
#   ACTIVE  = TOTAL - SKIPPED - FIXME
#
# Neden test\s*\(['\"] kullanıyoruz:
#   - test.describe( → elenir (test adı değil, suite wrapper)
#   - test.skip(     → dahil edilir (skip'li test de envanterde sayılır)
#   - test('...'     → dahil edilir
# ---------------------------------------------------------------------------
count_tests_in_content() {
  # Stdin'den içerik alır, 4 sayı döner: total skipped fixme active
  local content
  content=$(cat)

  local total skipped fixme active

  # Tüm test satırları: test(  test.skip(  test.fixme(  test.only(
  # test.describe( ELENİR çünkü describe'dan sonra ( gelir ama string başlamaz
  total=$(echo "$content" | grep -cE "^\s*test(\.(skip|fixme|only))?\s*\(['\"]" || true)
  total=${total:-0}

  skipped=$(echo "$content" | grep -cE "^\s*test\.skip\s*\(['\"]|^\s*test\.describe\.skip\s*\(" || true)
  skipped=${skipped:-0}

  fixme=$(echo "$content" | grep -cE "^\s*test\.fixme\s*\(['\"]|^\s*test\.describe\.fixme\s*\(" || true)
  fixme=${fixme:-0}

  active=$((total - skipped - fixme))
  if [ "$active" -lt 0 ]; then active=0; fi

  echo "$total $skipped $fixme $active"
}

# Current branch — tüm spec dosyalarını tara
TOTAL=0
SKIPPED=0
FIXME=0
ACTIVE=0

while IFS= read -r SPEC_FILE; do
  read -r t s f a < <(cat "$SPEC_FILE" | count_tests_in_content)
  TOTAL=$((TOTAL + t))
  SKIPPED=$((SKIPPED + s))
  FIXME=$((FIXME + f))
  ACTIVE=$((ACTIVE + a))
done < <(find "$TEST_ROOT" -name "*.spec.ts")

OVERALL_HEALTH=$(calc_health "$ACTIVE" "$TOTAL")

# ---------------------------------------------------------------------------
# Branch delta
#
# Fix 1 — Path-agnostic: klasör taşıma baseline'ı bozmaz
# Fix 2 — merge-base: başka branch merge edilse bu branch etkilenmez
# Fix 3 — Doğru sayma: skip/fixme de toplama dahil, test.describe elenir
# ---------------------------------------------------------------------------
BASELINE_TOTAL=0
BASELINE_ACTIVE=0
BASELINE_SKIPPED=0
BASELINE_FIXME=0
BRANCH_NEW_TESTS=0
BRANCH_REMOVED_TESTS=0
BRANCH_ACTIVATED_TESTS=0
BRANCH_DEACTIVATED_TESTS=0
MERGE_BASE_COMMIT=""
IS_FEATURE_BRANCH=false
PY_IS_FEATURE_BRANCH="False"

if [ "$BRANCH" != "master" ] && [ "$BRANCH" != "local" ]; then
  IS_FEATURE_BRANCH=true
  PY_IS_FEATURE_BRANCH="True"

  echo "Calculating branch delta against master..."

  git fetch origin master --quiet 2>/dev/null || true

  MERGE_BASE_COMMIT=$(git merge-base HEAD origin/master 2>/dev/null || echo "")
  if [ -z "$MERGE_BASE_COMMIT" ]; then
    echo "Warning: merge-base not found, falling back to origin/master HEAD"
    MERGE_BASE_COMMIT="origin/master"
  fi

  echo "Merge base commit: $MERGE_BASE_COMMIT"

  # Merge-base'deki tüm spec dosyalarını path'ten bağımsız oku
  # count_tests_in_content ile aynı sayma mantığını kullan
  while IFS= read -r SPEC; do
    read -r t s f a < <(git show "${MERGE_BASE_COMMIT}:${SPEC}" 2>/dev/null | count_tests_in_content)
    BASELINE_TOTAL=$((BASELINE_TOTAL + t))
    BASELINE_SKIPPED=$((BASELINE_SKIPPED + s))
    BASELINE_FIXME=$((BASELINE_FIXME + f))
    BASELINE_ACTIVE=$((BASELINE_ACTIVE + a))
  done < <(git ls-tree -r --name-only "$MERGE_BASE_COMMIT" 2>/dev/null | grep "\.spec\.ts$")

  # Delta hesapla
  TOTAL_DIFF=$((TOTAL - BASELINE_TOTAL))
  if [ "$TOTAL_DIFF" -gt 0 ]; then
    BRANCH_NEW_TESTS=$TOTAL_DIFF
  elif [ "$TOTAL_DIFF" -lt 0 ]; then
    BRANCH_REMOVED_TESTS=$(( -TOTAL_DIFF ))
  fi

  # Aktive edilen / deaktive edilen (skip/fixme ↔ active geçişi)
  ACTIVE_DIFF=$((ACTIVE - BASELINE_ACTIVE))
  if [ "$ACTIVE_DIFF" -gt "$BRANCH_NEW_TESTS" ]; then
    BRANCH_ACTIVATED_TESTS=$((ACTIVE_DIFF - BRANCH_NEW_TESTS))
  elif [ "$ACTIVE_DIFF" -lt 0 ]; then
    BRANCH_DEACTIVATED_TESTS=$(( -ACTIVE_DIFF ))
  fi

  echo "Baseline total:        $BASELINE_TOTAL"
  echo "Baseline active:       $BASELINE_ACTIVE"
  echo "Baseline skipped:      $BASELINE_SKIPPED"
  echo "Baseline fixme:        $BASELINE_FIXME"
  echo "-----------------------------"
  echo "Current total:         $TOTAL"
  echo "Current active:        $ACTIVE"
  echo "-----------------------------"
  echo "New tests added:       $BRANCH_NEW_TESTS"
  echo "Tests removed:         $BRANCH_REMOVED_TESTS"
  echo "Tests activated:       $BRANCH_ACTIVATED_TESTS"
  echo "Tests deactivated:     $BRANCH_DEACTIVATED_TESTS"
fi

# Global execution metrics
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

# ---------------------------------------------------------------------------
# İç içe modül desteği — spec dosyası olan her klasör ayrı modül
# ---------------------------------------------------------------------------
MODULES=$(find "$TEST_ROOT" -mindepth 1 -type d | sed "s|^${TEST_ROOT}/||" | sort)

for MODULE in $MODULES; do
  MOD_DIR="${TEST_ROOT}/${MODULE}"

  SPEC_COUNT=$(find "$MOD_DIR" -maxdepth 1 -name "*.spec.ts" | wc -l | tr -d ' ')
  if [ "$SPEC_COUNT" -eq 0 ]; then
    continue
  fi

  MOD_TOTAL=0
  MOD_ACTIVE=0
  MOD_FIXME=0
  MOD_SKIPPED=0

  if [ -f "$SAFE_RESULT_FILE" ]; then
    MOD_EXEC=$(jq --arg mod "$MODULE" '
      [
        .suites[]
        | select(.title | startswith($mod + "/") or . == $mod)
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

    read -r FILE_TOTAL FILE_SKIPPED FILE_FIXME FILE_ACTIVE < <(cat "$SPEC_FILE" | count_tests_in_content)

    FILE_HEALTH=$(calc_health "$FILE_ACTIVE" "$FILE_TOTAL")

    MOD_TOTAL=$((MOD_TOTAL + FILE_TOTAL))
    MOD_ACTIVE=$((MOD_ACTIVE + FILE_ACTIVE))
    MOD_FIXME=$((MOD_FIXME + FILE_FIXME))
    MOD_SKIPPED=$((MOD_SKIPPED + FILE_SKIPPED))

    if [ "$FIRST_FILE" -eq 1 ]; then FIRST_FILE=0; else FILES_JSON="$FILES_JSON,"; fi
    FILES_JSON="${FILES_JSON}{\"name\":\"${BASENAME}\",\"path\":\"${SPEC_FILE}\",\"module\":\"${MODULE}\",\"total\":${FILE_TOTAL},\"active\":${FILE_ACTIVE},\"fixme\":${FILE_FIXME},\"skipped\":${FILE_SKIPPED},\"health\":${FILE_HEALTH}}"

  done < <(find "$MOD_DIR" -maxdepth 1 -name "*.spec.ts" | sort)

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

if [ "$PERSIST_METRICS" != "true" ]; then
  echo "Skipping docs/data.json update for branch: $BRANCH"
  exit 0
fi

# Python bloğuna geçmeden önce tüm değişkenleri export et
export DATA_FILE RESULT_FILE FILES_JSON BY_MODULE_JSON
export DATE COMMIT BRANCH
export RUN_TYPE RUN_REASON RUN_LABEL RUN_FILTER
export PY_FULL_REGRESSION_EXECUTED PY_IS_FEATURE_BRANCH
export TOTAL ACTIVE FIXME SKIPPED OVERALL_HEALTH
export EXEC_TOTAL PASSED FAILED EXEC_SKIPPED PASS_RATE FAIL_RATE
export BASELINE_TOTAL BASELINE_ACTIVE BASELINE_SKIPPED BASELINE_FIXME
export BRANCH_NEW_TESTS BRANCH_REMOVED_TESTS BRANCH_ACTIVATED_TESTS BRANCH_DEACTIVATED_TESTS
export MERGE_BASE_COMMIT

python3 - <<'PYEOF'
import json, os
from pathlib import Path

DATA_FILE = os.environ.get("DATA_FILE", "docs/data.json")
RESULT_FILE = os.environ.get("RESULT_FILE", "test-results/results.json")
FILES_JSON = os.environ.get("FILES_JSON", "[]")
BY_MODULE_JSON = os.environ.get("BY_MODULE_JSON", "{}")

DATE = os.environ["DATE"]
COMMIT = os.environ["COMMIT"]
BRANCH = os.environ["BRANCH"]
RUN_TYPE = os.environ["RUN_TYPE"]
RUN_REASON = os.environ["RUN_REASON"]
RUN_LABEL = os.environ["RUN_LABEL"]
RUN_FILTER = os.environ["RUN_FILTER"]
PY_FULL_REGRESSION_EXECUTED = os.environ["PY_FULL_REGRESSION_EXECUTED"] == "True"
PY_IS_FEATURE_BRANCH = os.environ["PY_IS_FEATURE_BRANCH"] == "True"

TOTAL = int(os.environ["TOTAL"])
ACTIVE = int(os.environ["ACTIVE"])
FIXME = int(os.environ["FIXME"])
SKIPPED = int(os.environ["SKIPPED"])
OVERALL_HEALTH = int(os.environ["OVERALL_HEALTH"])
EXEC_TOTAL = int(os.environ["EXEC_TOTAL"])
PASSED = int(os.environ["PASSED"])
FAILED = int(os.environ["FAILED"])
EXEC_SKIPPED = int(os.environ["EXEC_SKIPPED"])
PASS_RATE = int(os.environ["PASS_RATE"])
FAIL_RATE = int(os.environ["FAIL_RATE"])
BASELINE_TOTAL = int(os.environ["BASELINE_TOTAL"])
BASELINE_ACTIVE = int(os.environ["BASELINE_ACTIVE"])
BASELINE_SKIPPED = int(os.environ["BASELINE_SKIPPED"])
BASELINE_FIXME = int(os.environ["BASELINE_FIXME"])
BRANCH_NEW_TESTS = int(os.environ["BRANCH_NEW_TESTS"])
BRANCH_REMOVED_TESTS = int(os.environ["BRANCH_REMOVED_TESTS"])
BRANCH_ACTIVATED_TESTS = int(os.environ["BRANCH_ACTIVATED_TESTS"])
BRANCH_DEACTIVATED_TESTS = int(os.environ["BRANCH_DEACTIVATED_TESTS"])
MERGE_BASE_COMMIT = os.environ.get("MERGE_BASE_COMMIT", "")

files = json.loads(FILES_JSON)
by_module = json.loads(BY_MODULE_JSON)

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
                    if file_path:
                        parts = file_path.replace("\\", "/").split("/")
                        module = "/".join(parts[:-1]) if len(parts) > 1 else "root"
                    else:
                        module = "root"
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
    "date": DATE,
    "commit": COMMIT,
    "branch": BRANCH,
    "runContext": {
        "type": RUN_TYPE,
        "reason": RUN_REASON,
        "label": RUN_LABEL,
        "filter": RUN_FILTER,
        "fullRegressionExecuted": PY_FULL_REGRESSION_EXECUTED
    },
    "summary": {
        "total": TOTAL,
        "active": ACTIVE,
        "fixme": FIXME,
        "skipped": SKIPPED,
        "health": OVERALL_HEALTH
    },
    "execution": {
        "total": EXEC_TOTAL,
        "passed": PASSED,
        "failed": FAILED,
        "skipped": EXEC_SKIPPED,
        "passRate": PASS_RATE,
        "failRate": FAIL_RATE
    },
    "branchDelta": {
        "isFeatureBranch": PY_IS_FEATURE_BRANCH,
        "mergeBaseCommit": MERGE_BASE_COMMIT,
        "baselineTotal": BASELINE_TOTAL,
        "baselineActive": BASELINE_ACTIVE,
        "baselineSkipped": BASELINE_SKIPPED,
        "baselineFixme": BASELINE_FIXME,
        "newTests": BRANCH_NEW_TESTS,
        "removedTests": BRANCH_REMOVED_TESTS,
        "activatedTests": BRANCH_ACTIVATED_TESTS,
        "deactivatedTests": BRANCH_DEACTIVATED_TESTS
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
    history = history[-30:]
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
PYEOF

echo "Metrics written to docs/data.json"