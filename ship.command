#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# ship.command — Cowork update-loop deploy script (v1.1)
#
# Reads project config from ~/Desktop/Cowork/projects.json based on
# the directory name, commits + pushes to GitHub, then polls Vercel
# until the deploy of THIS commit is READY.
#
# Usage:
#   Double-click in Finder       → prompts for a commit message
#   ./ship.command "msg"         → from Terminal, uses arg as message
# ─────────────────────────────────────────────────────────────────

set -e
cd "$(dirname "$0")"

KEYS=~/Desktop/Cowork/keys.txt
VERCEL_TOKEN=$(grep '^VERCEL_TOKEN=' "$KEYS" | cut -d= -f2-)
GITHUB_TOKEN=$(grep '^GITHUB_TOKEN=' "$KEYS" | cut -d= -f2-)
GH_AUTH="Authorization: Basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64)"
MANIFEST=~/Desktop/Cowork/projects.json
SLUG=$(basename "$PWD")

if [ -f "$MANIFEST" ]; then
  VERCEL_APP=$(python3 -c "import json; m=json.load(open('$MANIFEST')); print(m['projects'].get('$SLUG',{}).get('vercelApp',''))" 2>/dev/null)
  VERCEL_URL=$(python3 -c "import json; m=json.load(open('$MANIFEST')); print(m['projects'].get('$SLUG',{}).get('vercelUrl',''))" 2>/dev/null)
fi
VERCEL_APP=${VERCEL_APP:-$SLUG}
VERCEL_URL=${VERCEL_URL:-https://$VERCEL_APP.vercel.app}

echo ""
echo "═══════════════════════════════════════════"
echo "  Ship: $SLUG → $VERCEL_APP"
echo "═══════════════════════════════════════════"
echo ""

# ─── Commit message ───────────────────────────────
if [ -n "$1" ]; then
  MSG="$1"
else
  echo "What changed? (one line, then return)"
  read -r MSG
  if [ -z "$MSG" ]; then
    echo "✗ Commit message required."
    read -p "Press return to close..."
    exit 1
  fi
fi

# ─── Stage + commit ───────────────────────────────
if [ -z "$(git status --porcelain)" ]; then
  echo "ℹ No file changes. Nothing to ship."
  read -p "Press return to close..."
  exit 0
else
  echo "→ Staging..."
  git add .
  echo "→ Committing: $MSG"
  git -c user.email='jeff.mills@toptal.com' -c user.name='Jeff Mills' commit -m "$MSG"
fi

SHORT_SHA=$(git rev-parse --short HEAD)
FULL_SHA=$(git rev-parse HEAD)
echo "→ HEAD: $SHORT_SHA"

# ─── Push ─────────────────────────────────────────
AHEAD=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo 0)
if [ "$AHEAD" -gt 0 ]; then
  echo "→ Pushing $AHEAD commit(s) to origin/main..."
  git -c http.extraHeader="$GH_AUTH" push origin main
else
  echo "ℹ Already in sync with origin."
fi

# ─── Poll Vercel for OUR SHA to reach READY ───────
echo ""
echo "→ Waiting for Vercel to deploy $SHORT_SHA..."
START=$(date +%s)
TIMEOUT=300
LAST_STATE=""

while true; do
  RESPONSE=$(curl -s -H "Authorization: Bearer $VERCEL_TOKEN" \
    "https://api.vercel.com/v6/deployments?app=$VERCEL_APP&limit=10")

  PARSED=$(echo "$RESPONSE" | TARGET_SHA="$FULL_SHA" python3 -c "
import sys, json, os
target = os.environ.get('TARGET_SHA','')
try:
    d = json.load(sys.stdin)
    deps = d.get('deployments') or []
    for dep in deps:
        sha = dep.get('meta',{}).get('githubCommitSha','')
        if sha == target:
            print(f\"{dep.get('state','UNKNOWN')}|{dep.get('url','')}|{sha[:7]}\")
            break
    else:
        print('NOTFOUND||')
except Exception as e:
    print(f'PARSE_ERR||{e}')
" 2>/dev/null)

  STATE=$(echo "$PARSED" | cut -d'|' -f1)
  URL=$(echo "$PARSED" | cut -d'|' -f2)
  DEP_SHA=$(echo "$PARSED" | cut -d'|' -f3)
  ELAPSED=$(($(date +%s) - START))

  case "$STATE" in
    READY)
      # ─── Update manifest with lastShipped / lastShippedSha ───
      if [ -f "$MANIFEST" ]; then
        python3 -c "
import json
from datetime import datetime, timezone
m = json.load(open('$MANIFEST'))
if '$SLUG' in m.get('projects', {}):
    m['projects']['$SLUG']['lastShipped'] = datetime.now(timezone.utc).isoformat()
    m['projects']['$SLUG']['lastShippedSha'] = '$SHORT_SHA'
    json.dump(m, open('$MANIFEST', 'w'), indent=2)
    open('$MANIFEST', 'a').write('\n')
" 2>/dev/null && echo "  Manifest updated."
      fi

      echo ""
      echo "✓ READY"
      echo "  Production: $VERCEL_URL"
      echo "  Deployment: https://$URL"
      echo "  Commit:     $DEP_SHA  (matches push)"
      echo "  Time:       ${ELAPSED}s"
      read -p "Press return to close..."
      exit 0
      ;;
    ERROR|CANCELED)
      echo ""
      echo "✗ $STATE — see https://vercel.com/dashboard"
      read -p "Press return to close..."
      exit 1
      ;;
    NOTFOUND)
      if [ "$LAST_STATE" != "NOTFOUND" ]; then
        echo "  Waiting for Vercel to pick up the push... (${ELAPSED}s)"
        LAST_STATE="NOTFOUND"
      fi
      ;;
    PARSE_ERR)
      echo "  API parse error (${ELAPSED}s) — retrying"
      ;;
    *)
      if [ "$STATE" != "$LAST_STATE" ]; then
        echo "  $STATE (${ELAPSED}s)"
        LAST_STATE="$STATE"
      fi
      ;;
  esac

  if [ $ELAPSED -gt $TIMEOUT ]; then
    echo ""
    echo "⏱ Timeout after ${TIMEOUT}s. Last state: $STATE"
    echo "  Check https://vercel.com/dashboard"
    echo ""
    echo "  Debug: last API response:"
    echo "$RESPONSE" | head -c 500
    echo ""
    read -p "Press return to close..."
    exit 1
  fi

  sleep 4
done
