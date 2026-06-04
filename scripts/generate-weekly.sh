#!/bin/bash
# generate-weekly.sh — builds the weekly roundup from the current week's daily digest entries
# Called automatically by publish.sh on Sundays, or manually: bash scripts/generate-weekly.sh

set -e

PORTFOLIO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PORTFOLIO_DIR"

YEAR=$(date +%Y)
WEEK=$(date +%V)
WEEK_PADDED=$(printf "%02d" "$WEEK")

# ISO week: Mon-Sun. Get the Monday of this week.
WEEK_START=$(date -v-$(( $(date +%u) - 1 ))d +%Y-%m-%d 2>/dev/null || \
             date -d "$(date +%Y-%m-%d) -$(( $(date +%u) - 1 )) days" +%Y-%m-%d)

WEEK_END=$(date -v+$(( 7 - $(date +%u) ))d +%Y-%m-%d 2>/dev/null || \
           date -d "$(date +%Y-%m-%d) +$(( 7 - $(date +%u) )) days" +%Y-%m-%d)

DIGEST_DIR="src/content/digest"
OUTFILE="${DIGEST_DIR}/${YEAR}-W${WEEK_PADDED}.md"

if [ -f "$OUTFILE" ]; then
  echo "Weekly roundup already exists: $OUTFILE"
  exit 0
fi

echo "==> Generating weekly roundup for Week ${WEEK} (${WEEK_START} to ${WEEK_END})..."

# Collect all daily .md files from this week, sorted ascending by date
ENTRIES=()
for f in "$DIGEST_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md; do
  [ -f "$f" ] || continue
  FILEDATE=$(basename "$f" .md)
  if [[ "$FILEDATE" >= "$WEEK_START" && "$FILEDATE" <= "$WEEK_END" ]]; then
    ENTRIES+=("$f")
  fi
done

if [ ${#ENTRIES[@]} -eq 0 ]; then
  echo "No daily entries found for Week ${WEEK}. Skipping."
  exit 0
fi

# Sort ascending
IFS=$'\n' SORTED=($(sort <<<"${ENTRIES[*]}")); unset IFS

# Parse title and description from each entry's frontmatter
declare -a TITLES
declare -a DESCRIPTIONS
declare -a DATES

for f in "${SORTED[@]}"; do
  FILEDATE=$(basename "$f" .md)
  # Extract title: line starting with 'title:'
  TITLE=$(grep -m1 '^title:' "$f" | sed 's/^title: *"//' | sed 's/"$//' | sed "s/^title: *'//;s/'$//")
  # Extract description
  DESC=$(grep -m1 '^description:' "$f" | sed 's/^description: *"//' | sed 's/"$//' | sed "s/^description: *'//;s/'$//")
  TITLES+=("$TITLE")
  DESCRIPTIONS+=("$DESC")
  DATES+=("$FILEDATE")
done

# Format the publish date as the Sunday of this week
PUBLISH_DATE="$WEEK_END"

# Count entries
ENTRY_COUNT=${#SORTED[@]}

# Build the "Best Of" section
BEST_OF_SECTION=""
for i in "${!SORTED[@]}"; do
  NUM=$((i + 1))
  FILEDATE="${DATES[$i]}"
  TITLE="${TITLES[$i]}"
  DESC="${DESCRIPTIONS[$i]}"
  SLUG=$(basename "${SORTED[$i]}" .md)
  DISPLAY_DATE=$(date -j -f "%Y-%m-%d" "$FILEDATE" "+%B %-d" 2>/dev/null || \
                 date -d "$FILEDATE" "+%B %-d" 2>/dev/null || echo "$FILEDATE")
  BEST_OF_SECTION="${BEST_OF_SECTION}
### ${NUM}. ${TITLE} — *${DISPLAY_DATE}*

${DESC}

"
done

# Write the file
cat > "$OUTFILE" << FRONTMATTER
---
title: "Week ${WEEK} Roundup — ${YEAR}"
description: "The week's best across AI, engineering, markets, and big tech — with a Cloudflare lens."
date: "${PUBLISH_DATE}"
type: "weekly"
week: ${WEEK}
---

<!-- PUBLIC SOURCES ONLY — no cfdata.org, Salesforce, internal pricing, or Cloudflare MCP data -->

## The Big Picture

${ENTRY_COUNT} entries this week. The common thread across all of them: the gap between moving fast and moving well is widening. AI is accelerating every layer of the stack — capital markets, product decisions, infrastructure spend, and how code gets written — and the teams and companies winning are the ones that built strong foundations before the tools arrived, not the ones sprinting hardest now.

## Best Of This Week
${BEST_OF_SECTION}
## One Thing I'm Watching

The compounding effect of AI capex commitments across Big Tech. Google, Meta, and now SpaceX are all raising or deploying massive capital this week. That pressure has to generate revenue eventually, and the usage-based platforms — Workers AI included — are positioned to capture a slice of every workload that doesn't justify hyperscaler-scale infrastructure. Worth watching how that shakes out in Q2 earnings commentary.
FRONTMATTER

echo "==> Generated: $OUTFILE"
