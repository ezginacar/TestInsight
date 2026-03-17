#!/bin/bash

set -e

DATA_FILE="docs/data.json"
TEST_ROOT="tests"
TMP_LIST_FILE="/tmp/playwright-test-list.txt"

DATE=$(date +"%Y-%m-%d")

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr -d '\n')
if [ "$BRANCH" = "HEAD" ] || [ -z "$BRANCH" ]; then
  BRANCH="local"
fi

COMMIT=$(git rev-parse --short HEAD 2>/dev/null | tr -d '\n')
if [ -z "$COMMIT" ]; then
  COMMIT="local"
fi

echo "Collecting Playwright test stats..."

npx playwright test --list 2>/dev/null > "$TMP_LIST_FILE"

TOTAL=$(grep '^\s*\[chromium\]' "$TMP_LIST_FILE" | wc -l | tr -d ' ')
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

OVERALL_HEALTH=$(calc_health "$ACTIVE" "$TOTAL")

echo "Total:   $TOTAL"
echo "Active:  $ACTIVE"
echo "Fixme:   $FIXME"
echo "Skipped: $SKIPPED"
echo "Health:  ${OVERALL_HEALTH}%"
echo "Date:    $DATE"
echo "Branch:  $BRANCH"
echo "Commit:  $COMMIT"

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

for SPEC_FILE in $(find "$TEST_ROOT"/ -name "*.spec.ts" | sort); do
  BASENAME=$(basename "$SPEC_FILE")

  if [[ "$SPEC_FILE" == *"/api/"* ]]; then
    TYPE="api"
  elif [[ "$SPEC_FILE" == *"/ui/"* ]]; then
    TYPE="ui"
  else
    TYPE="other"
  fi

  FILE_FIXME=$(grep -hoE 'test\.fixme|test\.describe\.fixme' "$SPEC_FILE" 2>/dev/null | wc -l | tr -d ' ')
  FILE_SKIPPED=$(grep -hoE 'test\.skip|test\.describe\.skip' "$SPEC_FILE" 2>/dev/null | wc -l | tr -d ' ')

  COUNT=$(grep '^\s*\[chromium\]' "$TMP_LIST_FILE" | grep "$BASENAME" | wc -l | tr -d ' ')
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
done
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
  "byType": $BY_TYPE_JSON,
  "files": $FILES_JSON
}

try:
    with open(data_file) as f:
        existing = json.load(f)
except:
    existing = {"project": "test-insight", "history": []}

history = existing.get("history", [])
history = [
    h for h in history
    if not (
        h.get("date") == new_entry["date"]
        and h.get("commit") == new_entry["commit"]
    )
]
history.append(new_entry)

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