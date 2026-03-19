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
RUN_TYPE="${RUN_TYPE:-full}"                 # full | critical | smoke
RUN_REASON="${RUN_REASON:-regular}"          # regular | holiday | release | hotfix | nightly
RUN_LABEL="${RUN_LABEL:-Standard Regression}"
RUN_FILTER="${RUN_FILTER:-all}"

FULL_REGRESSION_EXECUTED=true
PY_FULL_REGRESSION_EXECUTED="True"

if [[ "$RUN_TYPE" != "full" ]]; then
  FULL_REGRESSION_EXECUTED=false
  PY_FULL_REGRESSION_EXECUTED="False"
fi

# Persist rules
PERSIST_METRICS=false
if [[ "$BRANCH" == "master" || "$BRANCH" == feature* ]]; then
  PERSIST_METRICS=true
fi

# If there is no change to test spec files, avoid appending a new point to the history chart.
# This keeps the graph focused only on commits that actually touched tests.
SPEC_CHANGED=false

if [ ! -f "$DATA_FILE" ]; then
  # First run, need to create data.json
  SPEC_CHANGED=true
fi

# Check for changes between commits (CI-style)
if [ "$SPEC_CHANGED" != true ]; then
  BASE_REF="${GITHUB_EVENT_BEFORE:-}"
  HEAD_REF="${GITHUB_SHA:-HEAD}"

  if [ -z "$BASE_REF" ]; then
    # fallback to comparing against the previous commit
    if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
      BASE_REF="HEAD~1"
    fi
  fi

  if [ -z "$BASE_REF" ] || ! git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
    # if we can't resolve a previous commit, assume this is the first meaningful run
    SPEC_CHANGED=true
  else
    if git diff --name-only "$BASE_REF" "$HEAD_REF" -- 'tests/**/*.spec.ts' | grep -q .; then
      SPEC_CHANGED=true
    fi
  fi
fi

# Also treat local (unstaged/staged/untracked) spec file changes as meaningful
if [ "$SPEC_CHANGED" != true ]; then
  if git diff --name-only -- 'tests/**/*.spec.ts' | grep -q . ||
     git diff --cached --name-only -- 'tests/**/*.spec.ts' | grep -q . ||
     git ls-files --others --exclude-standard -- 'tests/**/*.spec.ts' | grep -q .; then
    SPEC_CHANGED=true
  fi
fi

if [ "$SPEC_CHANGED" != true ]; then
  echo "No spec changes detected; skipping metrics update."
  exit 0
fi

echo "Collecting Playwright test stats..."

# Preserve the last executed test run results before running `--list`, as `--list` will
# still respect the configured JSON reporter and overwrite the results file.
if [ -f "$RESULT_FILE" ]; then
  cp "$RESULT_FILE" "$SAFE_RESULT_FILE"
fi

PLAYWRIGHT_LIST=$(npx playwright test --list 2>/dev/null || true)

# Gerekirse debug için aç:
# echo "---- PLAYWRIGHT LIST START ----"
# printf '%s\n' "$PLAYWRIGHT_LIST"
# echo "---- PLAYWRIGHT LIST END ----"

calc_health() {
  local active=$1
  local total=$2

  if [ "$total" -eq 0 ]; then
    echo 0
  else
    echo $((active * 100 / total))
  fi
}

calc_rate() {
  local value=$1
  local total=$2

  if [ "$total" -eq 0 ]; then
    echo 0
  else
    echo $((value * 100 / total))
  fi
}

TOTAL=$(printf '%s\n' "$PLAYWRIGHT_LIST" | awk '/\[(api|ui)\]/{count++} END{print count+0}')

FIXME=$(grep -rhoE 'test\.fixme|test\.describe\.fixme' "$TEST_ROOT"/ 2>/dev/null | wc -l | tr -d ' ' || true)
SKIPPED=$(grep -rhoE 'test\.skip|test\.describe\.skip' "$TEST_ROOT"/ 2>/dev/null | wc -l | tr -d ' ' || true)

FIXME=${FIXME:-0}
SKIPPED=${SKIPPED:-0}

ACTIVE=$((TOTAL - FIXME - SKIPPED))
if [ "$ACTIVE" -lt 0 ]; then
  ACTIVE=0
fi

OVERALL_HEALTH=$(calc_health "$ACTIVE" "$TOTAL")

# Execution metrics from Playwright JSON report
# Test objeleri has("status") and has("results") ile bulunur.
# status değerleri: "expected" (passed), "unexpected" (failed), "skipped"
# Tek jq çağrısıyla üç değer birden parse edilir.
if [ -f "$SAFE_RESULT_FILE" ]; then
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
  ' "$SAFE_RESULT_FILE")
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
FIRST=1

API_TOTAL=0
API_ACTIVE=0
API_FIXME=0
API_SKIPPED=0

UI_TOTAL=0
UI_ACTIVE=0
UI_FIXME=0
UI_SKIPPED=0

OTHER_TOTAL=0
OTHER_ACTIVE=0
OTHER_FIXME=0
OTHER_SKIPPED=0

while IFS= read -r SPEC_FILE; do
  BASENAME=$(basename "$SPEC_FILE")

  if [[ "$SPEC_FILE" == *"/api/"* ]]; then
    TYPE="api"
  elif [[ "$SPEC_FILE" == *"/ui/"* ]]; then
    TYPE="ui"
  else
    TYPE="other"
  fi

  COUNT=$(printf '%s\n' "$PLAYWRIGHT_LIST" | awk -v file="$BASENAME" '
    /\[(api|ui)\]/ && index($0, file) {count++}
    END {print count+0}
  ')

  FILE_FIXME=$(grep -hoE 'test\.fixme|test\.describe\.fixme' "$SPEC_FILE" 2>/dev/null | wc -l | tr -d ' ' || true)
  FILE_SKIPPED=$(grep -hoE 'test\.skip|test\.describe\.skip' "$SPEC_FILE" 2>/dev/null | wc -l | tr -d ' ' || true)

  FILE_FIXME=${FILE_FIXME:-0}
  FILE_SKIPPED=${FILE_SKIPPED:-0}

  FILE_ACTIVE=$((COUNT - FILE_FIXME - FILE_SKIPPED))
  if [ "$FILE_ACTIVE" -lt 0 ]; then
    FILE_ACTIVE=0
  fi

  FILE_HEALTH=$(calc_health "$FILE_ACTIVE" "$COUNT")

  case "$TYPE" in
    api)
      API_TOTAL=$((API_TOTAL + COUNT))
      API_ACTIVE=$((API_ACTIVE + FILE_ACTIVE))
      API_FIXME=$((API_FIXME + FILE_FIXME))
      API_SKIPPED=$((API_SKIPPED + FILE_SKIPPED))
      ;;
    ui)
      UI_TOTAL=$((UI_TOTAL + COUNT))
      UI_ACTIVE=$((UI_ACTIVE + FILE_ACTIVE))
      UI_FIXME=$((UI_FIXME + FILE_FIXME))
      UI_SKIPPED=$((UI_SKIPPED + FILE_SKIPPED))
      ;;
    other)
      OTHER_TOTAL=$((OTHER_TOTAL + COUNT))
      OTHER_ACTIVE=$((OTHER_ACTIVE + FILE_ACTIVE))
      OTHER_FIXME=$((OTHER_FIXME + FILE_FIXME))
      OTHER_SKIPPED=$((OTHER_SKIPPED + FILE_SKIPPED))
      ;;
  esac

  if [ "$FIRST" -eq 1 ]; then
    FIRST=0
  else
    FILES_JSON="$FILES_JSON,"
  fi

  FILES_JSON="${FILES_JSON}{\"name\":\"${BASENAME}\",\"path\":\"${SPEC_FILE}\",\"type\":\"${TYPE}\",\"total\":${COUNT},\"active\":${FILE_ACTIVE},\"fixme\":${FILE_FIXME},\"skipped\":${FILE_SKIPPED},\"health\":${FILE_HEALTH}}"
done < <(find "$TEST_ROOT"/ -name "*.spec.ts" | sort)

FILES_JSON="$FILES_JSON]"

API_HEALTH=$(calc_health "$API_ACTIVE" "$API_TOTAL")
UI_HEALTH=$(calc_health "$UI_ACTIVE" "$UI_TOTAL")
OTHER_HEALTH=$(calc_health "$OTHER_ACTIVE" "$OTHER_TOTAL")

BY_TYPE_JSON="{
  \"api\": {
    \"total\": ${API_TOTAL},
    \"active\": ${API_ACTIVE},
    \"fixme\": ${API_FIXME},
    \"skipped\": ${API_SKIPPED},
    \"health\": ${API_HEALTH}
  },
  \"ui\": {
    \"total\": ${UI_TOTAL},
    \"active\": ${UI_ACTIVE},
    \"fixme\": ${UI_FIXME},
    \"skipped\": ${UI_SKIPPED},
    \"health\": ${UI_HEALTH}
  },
  \"other\": {
    \"total\": ${OTHER_TOTAL},
    \"active\": ${OTHER_ACTIVE},
    \"fixme\": ${OTHER_FIXME},
    \"skipped\": ${OTHER_SKIPPED},
    \"health\": ${OTHER_HEALTH}
  }
}"

echo "By type: $BY_TYPE_JSON"
echo "Files: $FILES_JSON"

if [ "$PERSIST_METRICS" != "true" ]; then
  echo "Skipping docs/data.json update for branch: $BRANCH"
  exit 0
fi

python3 - <<EOF
import json

data_file = "$DATA_FILE"
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
  "byType": $BY_TYPE_JSON,
  "files": $FILES_JSON
}

try:
    with open(data_file) as f:
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
        "byType": entry.get("byType"),
        "files": entry.get("files"),
    }

if last_entry is None or comparable_payload(last_entry) != comparable_payload(new_entry):
    history.append(new_entry)
    history = history[-6:]
else:
    # No meaningful change since the last recorded run (same test inventory and metrics).
    # Avoid rewriting the file so that charts / history don't get new points on every rerun.
    print("No meaningful inventory change detected; leaving", data_file, "unchanged.")
    import sys
    sys.exit(0)

result = {
    "project": existing.get("project", "test-insight"),
    "last_updated": new_entry["date"],
    "current": new_entry,
    "history": history
}

with open(data_file, "w") as f:
    json.dump(result, f, indent=2)

print("Saved to", data_file)
EOF

echo "Metrics written to docs/data.json"