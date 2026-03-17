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

echo "Collecting Playwright test stats..."

TOTAL=$(npx playwright test --list 2>/dev/null \
  | grep '^\s*\[chromium\]' \
  | wc -l \
  | tr -d ' ')

FIXME=$(grep -rn "test\.fixme" "$TEST_ROOT"/ 2>/dev/null | wc -l | tr -d ' ')
SKIPPED=$(grep -rn "test\.skip" "$TEST_ROOT"/ 2>/dev/null | wc -l | tr -d ' ')

ACTIVE=$((TOTAL - FIXME - SKIPPED))

echo "Total:   $TOTAL"
echo "Active:  $ACTIVE"
echo "Fixme:   $FIXME"
echo "Skipped: $SKIPPED"
echo "Date:    $DATE"
echo "Branch:  $BRANCH"
echo "Commit:  $COMMIT"

mkdir -p docs

FILES_JSON="["
FIRST=1
for SPEC_FILE in $(find "$TEST_ROOT"/ -name "*.spec.ts" | sort); do
  BASENAME=$(basename "$SPEC_FILE")
  COUNT=$(npx playwright test --list 2>/dev/null \
    | grep "$BASENAME" \
    | wc -l | tr -d ' ')

  if [ "$FIRST" -eq 1 ]; then
    FIRST=0
  else
    FILES_JSON="$FILES_JSON,"
  fi

  FILES_JSON="${FILES_JSON}{\"name\":\"${BASENAME}\",\"count\":${COUNT}}"
done
FILES_JSON="$FILES_JSON]"

echo "Files: $FILES_JSON"

python3 - <<EOF
import json

data_file = "$DATA_FILE"
new_entry = {
  "date": "$DATE",
  "commit": "$COMMIT",
  "branch": "$BRANCH",
  "total": $TOTAL,
  "active": $ACTIVE,
  "fixme": $FIXME,
  "skipped": $SKIPPED,
  "files": $FILES_JSON
}

try:
    with open(data_file) as f:
        existing = json.load(f)
except:
    existing = {"project": "test-insight", "history": []}

history = existing.get("history", [])
history = [h for h in history if not (h["date"] == new_entry["date"] and h["commit"] == new_entry["commit"])]
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