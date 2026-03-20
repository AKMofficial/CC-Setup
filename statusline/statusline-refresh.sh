#!/usr/bin/env bash
# Background refresh script for block timer cache
# Fetches the current 5-hour usage block's endTime from ccusage
# Called asynchronously by statusline.sh when cache is stale

CACHE_FILE="$HOME/.claude/statusline-cache.json"
LOCK_FILE="$HOME/.claude/statusline-refresh.lock"

# Acquire lock — use flock if available (atomic), fall back to PID-based
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 0
    # flock: no cleanup needed — lock released when fd 9 closes on exit
else
    if [ -f "$LOCK_FILE" ]; then
        OLD_PID=$(<"$LOCK_FILE") 2>/dev/null || true
        if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
            exit 0
        fi
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
fi

# Fetch active block data from ccusage with timeout to prevent hangs
# timeout is GNU coreutils (Linux/WSL); macOS uses background+wait fallback
if command -v timeout >/dev/null 2>&1; then
    BLOCK_JSON=$(timeout 30 ccusage blocks --active --json --no-color --offline 2>/dev/null)
else
    TMPOUT="/tmp/ccusage_block_$$.json"
    ccusage blocks --active --json --no-color --offline >"$TMPOUT" 2>/dev/null &
    CCPID=$!
    for i in {1..30}; do
        kill -0 "$CCPID" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$CCPID" 2>/dev/null; then
        kill "$CCPID" 2>/dev/null
        BLOCK_JSON=""
    else
        wait "$CCPID" 2>/dev/null
        BLOCK_JSON=$(<"$TMPOUT") 2>/dev/null || true
    fi
    rm -f "$TMPOUT"
fi

if [ -z "$BLOCK_JSON" ]; then
    # ccusage failed, write error cache
    TEMP_FILE=$(mktemp)
    cat > "$TEMP_FILE" <<EOF
{
  "cached_at": $(date +%s),
  "error": true
}
EOF
    mv "$TEMP_FILE" "$CACHE_FILE"
    exit 1
fi

# Extract only the fields statusline.sh actually reads
IFS=$'\t' read -r BLOCK_END IS_ACTIVE <<< "$(echo "$BLOCK_JSON" | jq -r '[
  (.blocks[0].endTime // ""),
  (.blocks[0].isActive // false)
] | @tsv')"

# Guard against empty values from malformed ccusage output
BLOCK_END="${BLOCK_END:-""}"
IS_ACTIVE="${IS_ACTIVE:-false}"

# Write cache atomically (temp file + mv)
TEMP_FILE=$(mktemp)
cat > "$TEMP_FILE" <<EOF
{
  "cached_at": $(date +%s),
  "block_end_time": "$BLOCK_END",
  "is_active": $IS_ACTIVE
}
EOF
mv "$TEMP_FILE" "$CACHE_FILE"
