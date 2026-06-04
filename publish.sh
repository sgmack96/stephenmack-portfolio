#!/bin/bash
# publish.sh — stage digest content, auto-generate weekly roundup if it's Sunday, push to Cloudflare Pages

set -e

# Internal source patterns — any match hard-blocks the publish
BLOCKED_PATTERNS=(
  "cfdata\.org"
  "atlassian\.net/cloudflare"
  "salesforce\.com"
  "lightning\.force\.com"
  "cloudflare\.my\.salesforce"
  "internal\.cloudflare\.com"
)

scan_for_internal_sources() {
  local staged_files
  staged_files=$(git diff --cached --name-only | grep "^src/content/digest/")

  if [ -z "$staged_files" ]; then
    return 0
  fi

  local found=0
  for file in $staged_files; do
    for pattern in "${BLOCKED_PATTERNS[@]}"; do
      # Check the actual file content (not just the diff) for the pattern
      # Exclude HTML comment lines (the template reminder at the top of each file)
      matches=$(grep -in "$pattern" "$file" 2>/dev/null | grep -v "^[0-9]*:<!--" || true)
      if [ -n "$matches" ]; then
        if [ "$found" -eq 0 ]; then
          echo ""
          echo "BLOCKED: internal source detected — nothing was published."
          echo "------------------------------------------------------------"
        fi
        found=1
        echo "  File : $file"
        echo "  Match: $matches"
        echo ""
      fi
    done
  done

  if [ "$found" -eq 1 ]; then
    echo "Remove internal sources before publishing."
    echo "------------------------------------------------------------"
    git reset HEAD -- src/content/digest/ > /dev/null 2>&1
    exit 1
  fi
}

PORTFOLIO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PORTFOLIO_DIR"

DATE=$(date +%Y-%m-%d)
WEEK=$(date +%V)
YEAR=$(date +%Y)
DAY_OF_WEEK=$(date +%u)  # 1=Mon ... 7=Sun
WEEKLY_FILE="src/content/digest/${YEAR}-W${WEEK}.md"
DAILY_DIR="src/content/digest"

echo "==> Checking for new digest content..."

# Auto-generate weekly roundup on Sundays if it doesn't exist yet
if [ "$DAY_OF_WEEK" -eq 7 ] && [ ! -f "$WEEKLY_FILE" ]; then
  echo "==> Sunday detected — generating Week ${WEEK} roundup..."
  bash scripts/generate-weekly.sh
fi

# Stage all digest content
git add "$DAILY_DIR/"

# Check if anything is actually staged
if git diff --cached --quiet; then
  echo "Nothing new to publish."
  exit 0
fi

# Show what's being published
echo "==> Staging:"
git diff --cached --name-only

# Hard block — scan for internal sources before committing anything
echo "==> Scanning for internal sources..."
scan_for_internal_sources
echo "    Clean."

git commit -m "digest: $DATE"
git push origin main

echo ""
echo "Published. Live in ~60 seconds at:"
echo "  https://portfolio.macksportreport.com/digest"
