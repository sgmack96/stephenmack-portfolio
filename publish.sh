#!/bin/bash
# publish.sh — stage digest content, auto-generate weekly roundup if it's Sunday, push to Cloudflare Pages

set -e

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

git commit -m "digest: $DATE"
git push origin main

echo ""
echo "Published. Live in ~60 seconds at:"
echo "  https://portfolio.macksportreport.com/digest"
