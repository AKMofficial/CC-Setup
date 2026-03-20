#!/usr/bin/env bash
# Claude Code Custom Status Line
# Renders: ◆ Model │ Used/Max ▐████░░░░▌ XX% │ ⏱ Xh Xm

# ── Guard: ensure jq is available ──
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not found — install with: brew install jq (macOS) or apt install jq (Linux)"
    exit 1
fi

# ── Ensure UTF-8 locale for Unicode substring operations ──
# C.UTF-8 is available on minimal Linux; macOS only has en_US.UTF-8
# $OSTYPE is a bash builtin (zero forks)
if [[ "$OSTYPE" == "darwin"* ]]; then
    UTF8_LOCALE="en_US.UTF-8"
else
    UTF8_LOCALE="C.UTF-8"
fi
if [[ "${LC_ALL:-}" == "C" || "${LC_ALL:-}" == "POSIX" ]]; then
    export LC_ALL="$UTF8_LOCALE"
fi
export LC_CTYPE="${LC_CTYPE:-$UTF8_LOCALE}"

# ── Config ──
CACHE_FILE="$HOME/.claude/statusline-cache.json"
REFRESH_SCRIPT="$HOME/.claude/statusline-refresh.sh"
CACHE_TTL=300  # 5 minutes

# ── ANSI Colors ──
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
DIM_CYAN='\033[2;36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
WHITE='\033[37m'
GRAY='\033[90m'

# ── Read stdin JSON ──
INPUT=$(</dev/stdin)

# Single jq call to extract all needed fields (tab-separated)
# Clean model name in jq: strip everything from " (" onward
IFS=$'\t' read -r MODEL_NAME CTX_SIZE CTX_PCT <<< "$(echo "$INPUT" | jq -r '[
  ((.model.display_name // "Unknown") | split(" (")[0]),
  (.context_window.context_window_size // 200000),
  (.context_window.used_percentage // 0)
] | @tsv')"

# ── Format context window size (fully dynamic) ──
format_size() {
    local size=$1
    if [ "$size" -ge 1000000 ] 2>/dev/null; then
        echo "$((size / 1000000))M"
    elif [ "$size" -ge 1000 ] 2>/dev/null; then
        echo "$((size / 1000))K"
    else
        echo "$size"
    fi
}

CTX_MAX_LABEL=$(format_size "$CTX_SIZE")

# Truncate percentage to integer (pure bash, zero forks)
PCT_INT=${CTX_PCT%%.*}
PCT_INT=${PCT_INT:-0}

# Calculate current usage in tokens from percentage
CTX_USED=$((CTX_SIZE * PCT_INT / 100))
CTX_USED_LABEL=$(format_size "$CTX_USED")

CTX_LABEL="${CTX_USED_LABEL}/${CTX_MAX_LABEL}"

# ── Build progress bar ──

# Clamp to 0-100
[ "$PCT_INT" -lt 0 ] 2>/dev/null && PCT_INT=0
[ "$PCT_INT" -gt 100 ] 2>/dev/null && PCT_INT=100

# Select color based on usage
if [ "$PCT_INT" -lt 50 ]; then
    BAR_COLOR="$GREEN"
elif [ "$PCT_INT" -lt 80 ]; then
    BAR_COLOR="$YELLOW"
else
    BAR_COLOR="$RED"
fi

# Build bar (20 chars wide)
BAR_WIDTH=20
FILLED=$((PCT_INT * BAR_WIDTH / 100))
EMPTY=$((BAR_WIDTH - FILLED))

# Generate bar strings (pre-built, zero forks)
FULL="████████████████████"
NONE="░░░░░░░░░░░░░░░░░░░░"
FILLED_STR="${FULL:0:FILLED}"
EMPTY_STR="${NONE:0:EMPTY}"

BAR="${BAR_COLOR}▐${FILLED_STR}${GRAY}${EMPTY_STR}${BAR_COLOR}▌${RESET}"
PCT_DISPLAY="${BAR_COLOR}${PCT_INT}%${RESET}"

# ── Read billing cache ──
NOW=$(date +%s)
TIMER_DISPLAY=""
if [ -f "$CACHE_FILE" ]; then
    CACHE_DATA=$(<"$CACHE_FILE")
    IFS=$'\t' read -r CACHED_AT CACHE_ERROR BLOCK_END IS_ACTIVE <<< "$(echo "$CACHE_DATA" | jq -r '[
      (.cached_at // 0),
      (.error // false),
      (.block_end_time // ""),
      (.is_active // false)
    ] | @tsv')"

    if [ "$CACHE_ERROR" = "true" ]; then
        # ccusage likely missing or failed
        if ! command -v ccusage >/dev/null 2>&1; then
            TIMER_DISPLAY=" ${DIM}│${RESET} ${DIM}⏱ ccusage not found${RESET}"
        fi
    elif [ -n "$BLOCK_END" ] && [ "$IS_ACTIVE" = "true" ]; then
        # Calculate remaining time live from endTime
        # Strip fractional seconds and Z (pure bash, zero forks)
        BLOCK_END_CLEAN="${BLOCK_END%%.*}"
        BLOCK_END_CLEAN="${BLOCK_END_CLEAN%Z}"
        # Cross-platform date parsing (macOS + Linux/WSL) — single call
        BLOCK_END_EPOCH=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$BLOCK_END_CLEAN" +%s 2>/dev/null) || \
        BLOCK_END_EPOCH=$(date -u -d "${BLOCK_END_CLEAN}" +%s 2>/dev/null)

        if [ -n "$BLOCK_END_EPOCH" ]; then
            REMAINING_SECS=$((BLOCK_END_EPOCH - NOW))

            if [ "$REMAINING_SECS" -gt 0 ]; then
                REMAINING_HOURS=$((REMAINING_SECS / 3600))
                REMAINING_MINS=$(((REMAINING_SECS % 3600) / 60))

                # Format time string
                if [ "$REMAINING_HOURS" -gt 0 ]; then
                    TIME_STR="${REMAINING_HOURS}h ${REMAINING_MINS}m"
                else
                    TIME_STR="${REMAINING_MINS}m"
                fi

                # Color based on urgency
                if [ "$REMAINING_SECS" -gt 7200 ]; then
                    TIMER_COLOR="$GREEN"
                elif [ "$REMAINING_SECS" -gt 1800 ]; then
                    TIMER_COLOR="$YELLOW"
                else
                    TIMER_COLOR="$RED"
                fi

                TIMER_DISPLAY=" ${DIM}│${RESET} ${TIMER_COLOR}⏱ ${TIME_STR}${RESET}"
            else
                TIMER_DISPLAY=" ${DIM}│${RESET} ${DIM}⏱ block ended${RESET}"
            fi
        fi
    fi

    # Check cache freshness, spawn background refresh if stale
    # The refresh script handles its own locking internally
    CACHE_AGE=$((NOW - CACHED_AT))
    if [ "$CACHE_AGE" -gt "$CACHE_TTL" ]; then
        bash "$REFRESH_SCRIPT" </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null
    fi
else
    # No cache exists, show placeholder and trigger refresh
    TIMER_DISPLAY=" ${DIM}│${RESET} ${DIM}⏱ ...${RESET}"
    bash "$REFRESH_SCRIPT" </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null
fi

# ── Render ──
printf "${DIM_CYAN}◆ %s${RESET} ${DIM}│${RESET} ${WHITE}%s${RESET} %b %b%b\n" \
    "$MODEL_NAME" \
    "$CTX_LABEL" \
    "$BAR" \
    "$PCT_DISPLAY" \
    "$TIMER_DISPLAY"
