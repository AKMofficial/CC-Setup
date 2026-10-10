#!/usr/bin/env bash
# Claude Code Custom Status Line
# Renders: ◆ Model ⚡ (effort) │ Used/Max ▐████░░░░▌ XX% (cache 4m) │ 5h XX% ↻ 2h14m │ 7d XX% ↻ 3d4h

# ── Guard: ensure jq is available ──
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not found; install with: brew install jq (macOS) or apt install jq (Linux)"
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
# Plan limits shared by all sessions: each session only gets fresh rate_limits
# on its own API responses, so idle sessions would otherwise show stale usage
LIMITS_FILE="$HOME/.claude/statusline-limits.json"

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

# ── Read stdin JSON + shared limits ──
INPUT=$(cat)
SHARED=""
[ -f "$LIMITS_FILE" ] && SHARED=$(<"$LIMITS_FILE")

# Single jq call to extract all needed fields (tab-separated)
# - Model name: strip everything from " (" onward
# - Effort: absent when the model doesn't support the effort parameter
# - Cache: seconds until the prompt cache goes cold, "cold", or "-" when
#   unknown (before the first response, or caching not reported)
# - Context tokens: same input-only formula Claude Code uses for used_percentage
# - Limits: merge this session's rate_limits with the shared file, keeping the
#   freshest reading per window. Within one window usage only grows, and a new
#   window resets at least 5h (or 7d) after the old one, so a later resets_at
#   (by over an hour) means a newer window; otherwise the higher usage is newer.
#   Windows past their reset are dropped.
# - Absent values become "-": bash `read` collapses consecutive tabs, so an
#   empty field would shift every value after it
IFS=$'\t' read -r MODEL_NAME FAST EFFORT CTX_SIZE CTX_PCT CTX_TOKENS CACHE_SECS FIVE_PCT FIVE_SECS WEEK_PCT WEEK_SECS LIMITS_CHANGED LIMITS_JSON <<< "$(
  echo "$INPUT" | jq -r --arg shared "$SHARED" '
    def live: if (.used_percentage | type) == "number" and (.resets_at | type) == "number" and .resets_at > now
              then {used_percentage, resets_at} else null end;
    def fresher($a; $b):
      if $a == null then $b elif $b == null then $a
      elif $a.resets_at - $b.resets_at > 3600 then $a
      elif $b.resets_at - $a.resets_at > 3600 then $b
      elif $a.used_percentage >= $b.used_percentage then $a else $b end;
    def show: if . == null then "-", "-" else (.used_percentage | round), (.resets_at - now | floor) end;

    (try ($shared | fromjson) catch null) as $old
    | {
        five_hour: fresher(.rate_limits.five_hour | live; $old.five_hour | live),
        seven_day: fresher(.rate_limits.seven_day | live; $old.seven_day | live)
      } as $limits
    | .context_window.current_usage as $u
    | .prompt_cache as $c
    | [
        ((.model.display_name // "Unknown") | split(" (")[0]),
        (if .fast_mode == true then "on" else "-" end),
        (.effort.level // "-"),
        (.context_window.context_window_size // 200000),
        (.context_window.used_percentage // 0),
        (if $u then ($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0) else "-" end),
        (if $c.caching_observed != true then "-"
         elif $c.warm == true and ($c.expires_at | type) == "number" and $c.expires_at > now then ($c.expires_at - now | floor)
         else "cold" end),
        ($limits.five_hour | show),
        ($limits.seven_day | show),
        ($limits != ($old // {} | {five_hour: (.five_hour | live), seven_day: (.seven_day | live)})),
        ($limits | tojson)
      ] | @tsv'
)"

# Write shared limits only when this session saw something newer
# Atomic (temp file + mv) so concurrent sessions never read a partial file
if [ "$LIMITS_CHANGED" = "true" ]; then
    printf '%s\n' "$LIMITS_JSON" > "$LIMITS_FILE.$$" && mv -f "$LIMITS_FILE.$$" "$LIMITS_FILE"
fi

# ── Helpers ──

# Format token counts (fully dynamic)
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

# usage_color <pct>: sets COLOR: green (<50%), yellow (50-79%), red (80%+)
usage_color() {
    if [ "$1" -lt 50 ]; then
        COLOR="$GREEN"
    elif [ "$1" -lt 80 ]; then
        COLOR="$YELLOW"
    else
        COLOR="$RED"
    fi
}

# format_duration <seconds>: sets DURATION to a compact countdown (3d4h, 2h14m, 9m, <1m)
format_duration() {
    local s=$1
    local d=$((s / 86400)) h=$((s % 86400 / 3600)) m=$((s % 3600 / 60))
    if [ "$d" -gt 0 ]; then
        DURATION="${d}d${h}h"
    elif [ "$h" -gt 0 ]; then
        DURATION="${h}h${m}m"
    elif [ "$m" -gt 0 ]; then
        DURATION="${m}m"
    else
        DURATION="<1m"
    fi
}

# ── Pieces ──
# The line is built from pieces, each with a drop priority. When it doesn't fit
# the window ($COLUMNS, set by Claude Code), pieces are dropped lowest
# priority first instead of the end of the line getting cut off:
#   1 context bar, 2 7d countdown, 3 5h countdown, 4 context tokens,
#   5 cache, 6 effort; 0 = always kept
PIECES=()
PIECE_PRIOS=()
PIECE_WIDTHS=()
ESC_SEQ='\033['

# add_piece <prio> <text> [extra_width]: extra_width covers double-width glyphs
add_piece() {
    local rest=$2 plain=""
    # Visible width: strip "\033[...m" color codes (literal until printf %b)
    while [[ "$rest" == *"$ESC_SEQ"* ]]; do
        plain+="${rest%%"$ESC_SEQ"*}"
        rest="${rest#*"$ESC_SEQ"}"
        rest="${rest#*m}"
    done
    plain+="$rest"
    PIECES+=("$2")
    PIECE_PRIOS+=("$1")
    PIECE_WIDTHS+=($(( ${#plain} + ${3:-0} )))
}

SEP=" ${DIM}│${RESET} "

# ── Model + fast mode + effort ──
add_piece 0 "${DIM_CYAN}◆ ${MODEL_NAME}${RESET}"
[ "$FAST" = "on" ] && add_piece 0 " ⚡" 1
[ "$EFFORT" != "-" ] && add_piece 6 "${DIM_CYAN} (${EFFORT})${RESET}"

# ── Context window ──
CTX_MAX_LABEL=$(format_size "$CTX_SIZE")

# Truncate percentage to integer (pure bash, zero forks)
PCT_INT=${CTX_PCT%%.*}
PCT_INT=${PCT_INT:-0}

# Exact token count when available (null before the first response and right
# after /compact), else estimate from the percentage
if [ "$CTX_TOKENS" = "-" ]; then
    CTX_TOKENS=$((CTX_SIZE * PCT_INT / 100))
fi
CTX_LABEL="$(format_size "$CTX_TOKENS")/${CTX_MAX_LABEL}"

# Clamp to 0-100
[ "$PCT_INT" -lt 0 ] 2>/dev/null && PCT_INT=0
[ "$PCT_INT" -gt 100 ] 2>/dev/null && PCT_INT=100

usage_color "$PCT_INT"
BAR_COLOR="$COLOR"

# Build bar (20 chars wide)
BAR_WIDTH=20
FILLED=$((PCT_INT * BAR_WIDTH / 100))
EMPTY=$((BAR_WIDTH - FILLED))

# Generate bar strings (pre-built, zero forks)
FULL="████████████████████"
NONE="░░░░░░░░░░░░░░░░░░░░"
FILLED_STR="${FULL:0:FILLED}"
EMPTY_STR="${NONE:0:EMPTY}"

add_piece 0 "$SEP"
add_piece 4 "${WHITE}${CTX_LABEL}${RESET} "
add_piece 1 "${BAR_COLOR}▐${FILLED_STR}${GRAY}${EMPTY_STR}${BAR_COLOR}▌${RESET} "
add_piece 0 "${BAR_COLOR}${PCT_INT}%${RESET}"

# ── Prompt cache (inside the context group) ──
# Countdown until the cache expires; once cold, the next message re-processes
# the whole conversation (slower, and uses more of the plan limits)
if [ "$CACHE_SECS" = "cold" ]; then
    add_piece 5 " ${GRAY}(cache${RESET} ${YELLOW}cold${RESET}${GRAY})${RESET}"
elif [ "$CACHE_SECS" != "-" ]; then
    format_duration "$CACHE_SECS"
    CACHE_COLOR="$GRAY"
    [ "$CACHE_SECS" -lt 60 ] && CACHE_COLOR="$YELLOW"
    add_piece 5 " ${GRAY}(cache${RESET} ${CACHE_COLOR}${DURATION}${RESET}${GRAY})${RESET}"
fi

# ── Plan usage limits ──
# add_limit <label> <pct> <secs_left> <countdown_prio>: adds "│ 5h 23% ↻ 2h14m"
# Skipped when the window is unknown (API key login, or no response seen yet)
# Usage is bold from 80% so it stands out when it matters
add_limit() {
    local label=$1 pct=$2 secs=$3
    [ "$pct" = "-" ] && return
    usage_color "$pct"
    local weight=""
    [ "$pct" -ge 80 ] && weight="$BOLD"
    format_duration "$secs"
    add_piece 0 "${SEP}${GRAY}${label}${RESET} ${weight}${COLOR}${pct}%${RESET}"
    add_piece "$4" " ${GRAY}↻ ${DURATION}${RESET}"
}

add_limit "5h" "$FIVE_PCT" "$FIVE_SECS" 3
add_limit "7d" "$WEEK_PCT" "$WEEK_SECS" 2

# ── Fit to window ──
# Margin covers Claude Code's own indent around the status line
WIDTH_MARGIN=4
MAX_WIDTH=-1
[[ "${COLUMNS:-}" =~ ^[0-9]+$ ]] && MAX_WIDTH=$((COLUMNS - WIDTH_MARGIN))

TOTAL=0
for w in "${PIECE_WIDTHS[@]}"; do TOTAL=$((TOTAL + w)); done

DROP_BELOW=1  # pieces with 0 < prio < DROP_BELOW are dropped
if [ "$MAX_WIDTH" -ge 0 ]; then
    while [ "$TOTAL" -gt "$MAX_WIDTH" ] && [ "$DROP_BELOW" -le 6 ]; do
        for i in "${!PIECES[@]}"; do
            [ "${PIECE_PRIOS[$i]}" -eq "$DROP_BELOW" ] && TOTAL=$((TOTAL - PIECE_WIDTHS[i]))
        done
        DROP_BELOW=$((DROP_BELOW + 1))
    done
fi

# ── Render ──
LINE=""
for i in "${!PIECES[@]}"; do
    prio=${PIECE_PRIOS[$i]}
    [ "$prio" -gt 0 ] && [ "$prio" -lt "$DROP_BELOW" ] && continue
    LINE+="${PIECES[$i]}"
done
printf '%b\n' "$LINE"
