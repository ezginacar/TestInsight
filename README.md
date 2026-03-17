## Summary TR

TestInsight, otomasyon projelerinde master/main üzerindeki toplam test envanteri ile branch bazlı yeni test artışını birbirinden ayırarak yorumlamayı hedefler.

Böylece:
- mevcut toplam test sayısı
- son master koşum başarısı
- branch içinde eklenen yeni test sayısı
- yeni testlerin merge öncesi başarısı

aynı dashboard üzerinde ayrı metrikler olarak görülebilir.


# TestInsight

> Understand your test suite beyond just execution results.

TestInsight is a dashboard-driven test metrics project designed to visualize automated test inventory and execution trends across different branches.

---

## Problem

In many automation projects, test metrics are interpreted incorrectly.

A branch may contain only a few newly added test cases, but that does NOT represent the total size of the automation suite.

For example:

- main/master may already contain 100 existing test cases  
- a feature branch may introduce 3 new test cases  
- those 3 tests may pass successfully  

Incorrect interpretation:
→ "Only 3 test cases exist"

Correct interpretation:
→ 100 existing tests + 3 newly added tests

TestInsight aims to separate these perspectives clearly.

---

## Goals

TestInsight focuses on four metric perspectives:

1. **Baseline Test Inventory**  
   Total number of test cases available on main/master.

2. **Baseline Execution Status**  
   Latest execution success/failure information for the baseline suite.

3. **Branch / PR Delta**  
   Number of newly added, removed, or modified test cases in a feature branch.

4. **New Test Execution Status**  
   Pass/fail information for the newly added test cases before merge.

---

## Why It Matters

This distinction helps teams avoid misleading interpretations such as:

- “Only 3 test cases exist”

When in reality:

- 100 tests already exist on main/master  
- 3 additional tests are being introduced in the current branch  

---

## How It Works

TestInsight collects and structures test metrics using a lightweight approach.

Current implementation:

- Uses Playwright CLI to list test cases
- Parses test files to calculate test distribution
- Tracks:
  - total test count
  - active / skipped / fixme tests
  - file-based test breakdown
- Stores historical metrics in `docs/data.json`
- Each run appends a new snapshot for trend analysis

This enables tracking how the test suite evolves over time.

---

## Example Output

```json
{
  "total": 102,
  "active": 98,
  "fixme": 2,
  "skipped": 2,
  "files": [
    { "name": "auth.spec.ts", "count": 20 },
    { "name": "order.spec.ts", "count": 15 }
  ]
}
