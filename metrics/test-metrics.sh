#!/bin/bash

# ─────────────────────────────────────────
# Playwright Test Stats Collector
# Runs on every merge to master
# Outputs: docs/data.json
# ─────────────────────────────────────────

set -e

DATA_FILE="docs/data.json"
DATE=$(date +"%Y-%m-%d")
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

echo "Collecting Playwright test stats..."

# ── Total unique tests (chromium only to avoid browser multiplication)
TOTAL=$(npx playwright test --list 2>/dev/null \
  | grep '^\s*\[chromium\]' \
  | wc -l \
  | tr -d ' ')

# ── Fixme tests
FIXME=$(grep -rn "test\.fixme" tests/ 2>/dev/null | wc -l | tr -d ' ')

# ── Skipped tests
SKIPPED=$(grep -rn "test\.skip" tests/ 2>/dev/null | wc -l | tr -d ' ')

# ── Active = total - fixme - skipped
ACTIVE=$((TOTAL - FIXME - SKIPPED))

echo "Total:   $TOTAL"
echo "Active:  $ACTIVE"
echo "Fixme:   $FIXME"
echo "Skipped: $SKIPPED"
echo "Date:    $DATE"
echo "Branch:  $BRANCH"

# ── Create docs/ folder if not exists
mkdir -p docs

# ── File breakdown
FILES_JSON="["
FIRST=1
for SPEC_FILE in $(find tests/ -name "*.spec.ts" | sort); do
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

# ── Write data.json via python
python3 - <<EOF
import json
from datetime import datetime

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
echo "Metrics written to docs/data.json"