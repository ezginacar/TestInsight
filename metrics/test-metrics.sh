#!/bin/bash

set -e

DATA_FILE="docs/data.json"
TEST_ROOT="tests"
RESULT_FILE="test-results/results.json"
PROJECT_PATTERN='^\s*\[(api|ui)\]'

DATE=$(date +"%Y-%m-%d")

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr -d '\n')
if [ "$BRANCH" = "HEAD" ] || [ -z "$BRANCH" ]; then
  BRANCH="local"
fi

COMMIT=$(git rev-parse --short HEAD 2>/dev/null | tr -d '\n')
if [ -z "$COMMIT" ]; then
  COMMIT="local"
fi

PERSIST_METRICS=false
if [[ "$BRANCH" == "master" ]]; then
  PERSIST_METRICS=true
fi

echo "Collecting Playwright test stats..."

PLAYWRIGHT_LIST=$(npx playwright test --list --reporter=list 2>/dev/null)

TOTAL=$(echo "$PLAYWRIGHT_LIST" \
  | grep -E "$PROJECT_PATTERN" \
  | wc -l \
  | tr -d ' ')

FIXME=$(grep -rhoE 'test\.fixme|test\.describe\.fixme' "$TEST_ROOT"/ 2>/dev/null | wc -l | tr -d ' ')
SKIPPED=$(grep -rhoE 'test\.skip|test\.describe\.skip' "$TEST_ROOT"/ 2>/dev/null | wc -l | tr -d ' ')

ACTIVE=$((TOTAL - FIXME - SKIPPED))
if [ "$ACTIVE" -lt 0 ]; then
  ACTIVE=0
fi

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

OVERALL_HEALTH=$(calc_health "$ACTIVE" "$TOTAL")

# Execution metrics from Playwright JSON report
if [ -f "$RESULT_FILE" ]; then
  PASSED=$(jq '[.. | objects | select(has("results")) | .status | select(. == "passed")] | length' "$RESULT_FILE")
  FAILED=$(jq '[.. | objects | select(has("results")) | .status | select(. == "failed")] | length' "$RESULT_FILE")
  EXEC_SKIPPED=$(jq '[.. | objects | select(has("results")) | .status | select(. == "skipped")] | length' "$RESULT_FILE")
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
echo "Execution total: $EXEC_TOTAL"
echo "Passed:          $PASSED"
echo "Failed:          $FAILED"
echo "Exec skipped:    $EXEC_SKIPPED"
echo "Pass rate:       ${PASS_RATE}%"
echo "Fail rate:       ${FAIL_RATE}%"
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

  COUNT=$(echo "$PLAYWRIGHT_LIST" \
    | grep -E "$PROJECT_PATTERN" \
    | grep "$BASENAME" \
    | wc -l | tr -d ' ')

  FILE_FIXME=$(grep -hoE 'test\.fixme|test\.describe\.fixme' "$SPEC_FILE" 2>/dev/null | wc -l | tr -d ' ')
  FILE_SKIPPED=$(grep -hoE 'test\.skip|test\.describe\.skip' "$SPEC_FILE" 2>/dev/null | wc -l | tr -d ' ')
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
except:
    existing = {"project": "test-insight", "history": []}

history = existing.get("history", [])

# aynı commit + aynı date varsa önce temizle
history = [
    h for h in history
    if not (
        h.get("date") == new_entry["date"]
        and h.get("commit") == new_entry["commit"]
    )
]

last_entry = history[-1] if history else None

def comparable_payload(entry):
    return {
        "summary": entry.get("summary"),
        "byType": entry.get("byType"),
        "files": entry.get("files"),
    }

# current her zaman güncellenir
# history sadece inventory değiştiyse büyür
if last_entry is None or comparable_payload(last_entry) != comparable_payload(new_entry):
    history.append(new_entry)
    history = history[-6:]  # son 6 anlamlı event'i tut
else:
    print("No inventory change detected, skipping history append.")

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

echo "Metrics written to docs/data.json"#!/bin/bash

set -e

DATA_FILE="docs/data.json"
TEST_ROOT="tests"
RESULT_FILE="test-results/results.json"
PROJECT_PATTERN='^\s*\[(api|ui)\]'

DATE=$(date +"%Y-%m-%d")

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr -d '\n')
if [ "$BRANCH" = "HEAD" ] || [ -z "$BRANCH" ]; then
  BRANCH="local"
fi

COMMIT=$(git rev-parse --short HEAD 2>/dev/null | tr -d '\n')
if [ -z "$COMMIT" ]; then
  COMMIT="local"
fi

PERSIST_METRICS=false
if [[ "$BRANCH" == "master" ]]; then
  PERSIST_METRICS=true
fi

echo "Collecting Playwright test stats..."

PLAYWRIGHT_LIST=$(npx playwright test --list --reporter=list 2>/dev/null)

TOTAL=$(echo "$PLAYWRIGHT_LIST" \
  | grep -E "$PROJECT_PATTERN" \
  | wc -l \
  | tr -d ' ')

FIXME=$(grep -rhoE 'test\.fixme|test\.describe\.fixme' "$TEST_ROOT"/ 2>/dev/null | wc -l | tr -d ' ')
SKIPPED=$(grep -rhoE 'test\.skip|test\.describe\.skip' "$TEST_ROOT"/ 2>/dev/null | wc -l | tr -d ' ')

ACTIVE=$((TOTAL - FIXME - SKIPPED))
if [ "$ACTIVE" -lt 0 ]; then
  ACTIVE=0
fi

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

OVERALL_HEALTH=$(calc_health "$ACTIVE" "$TOTAL")

# Execution metrics from Playwright JSON report
if [ -f "$RESULT_FILE" ]; then
  PASSED=$(jq '[.. | objects | select(has("results")) | .status | select(. == "passed")] | length' "$RESULT_FILE")
  FAILED=$(jq '[.. | objects | select(has("results")) | .status | select(. == "failed")] | length' "$RESULT_FILE")
  EXEC_SKIPPED=$(jq '[.. | objects | select(has("results")) | .status | select(. == "skipped")] | length' "$RESULT_FILE")
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
echo "Execution total: $EXEC_TOTAL"
echo "Passed:          $PASSED"
echo "Failed:          $FAILED"
echo "Exec skipped:    $EXEC_SKIPPED"
echo "Pass rate:       ${PASS_RATE}%"
echo "Fail rate:       ${FAIL_RATE}%"
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

  COUNT=$(echo "$PLAYWRIGHT_LIST" \
    | grep -E "$PROJECT_PATTERN" \
    | grep "$BASENAME" \
    | wc -l | tr -d ' ')

  FILE_FIXME=$(grep -hoE 'test\.fixme|test\.describe\.fixme' "$SPEC_FILE" 2>/dev/null | wc -l | tr -d ' ')
  FILE_SKIPPED=$(grep -hoE 'test\.skip|test\.describe\.skip' "$SPEC_FILE" 2>/dev/null | wc -l | tr -d ' ')
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
except:
    existing = {"project": "test-insight", "history": []}

history = existing.get("history", [])

# aynı commit + aynı date varsa önce temizle
history = [
    h for h in history
    if not (
        h.get("date") == new_entry["date"]
        and h.get("commit") == new_entry["commit"]
    )
]

last_entry = history[-1] if history else None

def comparable_payload(entry):
    return {
        "summary": entry.get("summary"),
        "byType": entry.get("byType"),
        "files": entry.get("files"),
    }

# current her zaman güncellenir
# history sadece inventory değiştiyse büyür
if last_entry is None or comparable_payload(last_entry) != comparable_payload(new_entry):
    history.append(new_entry)
    history = history[-6:]  # son 6 anlamlı event'i tut
else:
    print("No inventory change detected, skipping history append.")

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