#!/bin/bash

set -e

DATA_FILE="docs/data.json"
TEST_ROOT="tests"

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

PLAYWRIGHT_LIST=$(npx playwright test --list 2>/dev/null)

TOTAL=$(echo "$PLAYWRIGHT_LIST" \
  | grep '^\s*\[chromium\]' \
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

OVERALL_HEALTH=$(calc_health "$ACTIVE" "$TOTAL")

echo "Total:   $TOTAL"
echo "Active:  $ACTIVE"
echo "Fixme:   $FIXME"
echo "Skipped: $SKIPPED"
echo "Health:  ${OVERALL_HEALTH}%"
echo "Date:    $DATE"
echo "Branch:  $BRANCH"
echo "Commit:  $COMMIT"
echo "Persist: $PERSIST_METRICS"

mkdir -p docs

FILES_JSON="["
FIRST=1
for SPEC_FILE in $(find "$TEST_ROOT"/ -name "*.spec.ts" | sort); do
  BASENAME=$(basename "$SPEC_FILE")

  COUNT=$(echo "$PLAYWRIGHT_LIST" \
    | grep '^\s*\[chromium\]' \
    | grep "$BASENAME" \
    | wc -l | tr -d ' ')

  FILE_FIXME=$(grep -hoE 'test\.fixme|test\.describe\.fixme' "$SPEC_FILE" 2>/dev/null | wc -l | tr -d ' ')
  FILE_SKIPPED=$(grep -hoE 'test\.skip|test\.describe\.skip' "$SPEC_FILE" 2>/dev/null | wc -l | tr -d ' ')
  FILE_ACTIVE=$((COUNT - FILE_FIXME - FILE_SKIPPED))
  if [ "$FILE_ACTIVE" -lt 0 ]; then
    FILE_ACTIVE=0
  fi
  FILE_HEALTH=$(calc_health "$FILE_ACTIVE" "$COUNT")

  if [ "$FIRST" -eq 1 ]; then
    FIRST=0
  else
    FILES_JSON="$FILES_JSON,"
  fi

  FILES_JSON="${FILES_JSON}{\"name\":\"${BASENAME}\",\"path\":\"${SPEC_FILE}\",\"total\":${COUNT},\"active\":${FILE_ACTIVE},\"fixme\":${FILE_FIXME},\"skipped\":${FILE_SKIPPED},\"health\":${FILE_HEALTH}}"
done
FILES_JSON="$FILES_JSON]"

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