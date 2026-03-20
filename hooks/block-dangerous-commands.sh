#!/bin/bash
# PreToolUse: Block dangerous shell commands before execution.
set -e

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only check Bash tool calls
[ "$TOOL_NAME" != "Bash" ] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0

# --- Universal prefixes that should never be used ---
if echo "$CMD" | grep -qE '(^|[;&|]\s*)(sudo|doas)\s'; then
  echo "BLOCKED: sudo/doas should not be used." >&2
  exit 2
fi

if echo "$CMD" | grep -qE '(^|[;&|]\s*)su\s+-c\s'; then
  echo "BLOCKED: su -c should not be used." >&2
  exit 2
fi

if echo "$CMD" | grep -qE '(^|[;&|]\s*)eval\s'; then
  echo "BLOCKED: eval can bypass safety checks." >&2
  exit 2
fi

# --- Destructive file operations ---
# Normalize: detect rm with any combo of recursive+force (short or long flags)
RM_FORCE='rm\s+(-[a-zA-Z]*f[a-zA-Z]*|-[rR]\s+-f|-f\s+-[rR]|--force|--recursive\s+--force|--force\s+--recursive)'

# rm on root directory
if echo "$CMD" | grep -qE "$RM_FORCE\s+/(\s|$|\*)"; then
  echo "BLOCKED: rm on root directory." >&2
  exit 2
fi

# rm with force on system directories (never allowed)
if echo "$CMD" | grep -qE "${RM_FORCE}.*(~|/System|/Library|/usr|/bin|/sbin|/etc|/var|/tmp)"; then
  echo "BLOCKED: Destructive rm on system directory." >&2
  exit 2
fi

# rm with force on $HOME
if echo "$CMD" | grep -qE 'rm\s+.*--force.*(\$HOME|\$\{HOME\})' || \
   echo "$CMD" | grep -qE 'rm\s+.*-[a-zA-Z]*f.*(\$HOME|\$\{HOME\})'; then
  echo "BLOCKED: Destructive rm on home directory." >&2
  exit 2
fi

# rm with force on /Users/xxx or /home/xxx (shallow - only 0-1 segments after username)
# Blocks: rm -rf /Users, rm -rf /Users/<user>, rm -rf /home/<user>
# Allows: rm -rf /Users/<user>/Desktop/project/dist (3+ segments after /Users)
if echo "$CMD" | grep -qE "${RM_FORCE}\s+[\"']?/(Users|home)/[^/]*/?(\"|\x27|\s|$)" || \
   echo "$CMD" | grep -qE "${RM_FORCE}\s+[\"']?/(Users|home)/?(\"|\x27|\s|$)"; then
  echo "BLOCKED: Destructive rm on home directory." >&2
  exit 2
fi

# rm -rf . or ./ or ./* (current dir wipe, handles chaining)
if echo "$CMD" | grep -qE "${RM_FORCE}\s+\.(/?\*?)?(\s*$|\s*[;&|])"; then
  echo "BLOCKED: rm on current directory." >&2
  exit 2
fi

# rm -rf * (wipes current directory contents)
if echo "$CMD" | grep -qE "${RM_FORCE}\s+\*"; then
  echo "BLOCKED: rm -rf * wipes current directory contents." >&2
  exit 2
fi

# File truncation via : > pattern
if echo "$CMD" | grep -qE '(^|[;&|]\s*):\s*>'; then
  echo "BLOCKED: File truncation via : > pattern." >&2
  exit 2
fi

# --- Git danger ---
# Force push (--force but NOT --force-with-lease)
if echo "$CMD" | grep -qE 'git\s+push\s+.*--force\b' && ! echo "$CMD" | grep -qE 'force-with-lease'; then
  echo "BLOCKED: git push --force. Use --force-with-lease if needed." >&2
  exit 2
fi

# git push -f (short flag)
if echo "$CMD" | grep -qE 'git\s+push\s+.*\s-f\b'; then
  echo "BLOCKED: git push -f. Use --force-with-lease if needed." >&2
  exit 2
fi

# Hard reset
if echo "$CMD" | grep -qE 'git\s+reset\s+--hard'; then
  echo "BLOCKED: git reset --hard discards uncommitted work." >&2
  exit 2
fi

# Git clean -f (deletes untracked files)
if echo "$CMD" | grep -qE 'git\s+clean\s+(-[a-zA-Z]*f|.*--force)'; then
  echo "BLOCKED: git clean -f deletes untracked files permanently." >&2
  exit 2
fi

# Git push --delete (remote branch/tag deletion)
if echo "$CMD" | grep -qE 'git\s+push\s+.*--delete'; then
  echo "BLOCKED: git push --delete removes remote branches/tags." >&2
  exit 2
fi

# Git branch -D (force-delete local branch without merge check)
if echo "$CMD" | grep -qE 'git\s+branch\s+.*-D\b'; then
  echo "BLOCKED: git branch -D force-deletes without merge check." >&2
  exit 2
fi

# Git checkout -- / git restore (discards uncommitted changes)
if echo "$CMD" | grep -qE 'git\s+checkout\s+--\s+' || \
   echo "$CMD" | grep -qE 'git\s+restore\s+'; then
  echo "BLOCKED: git restore/checkout -- discards uncommitted changes." >&2
  exit 2
fi

# Git stash drop/clear (permanently lose stashed work)
if echo "$CMD" | grep -qE 'git\s+stash\s+(drop|clear)'; then
  echo "BLOCKED: git stash drop/clear loses stashed work permanently." >&2
  exit 2
fi

# Git rebase on shared branches (exact ref only - not feature/main-menu or main~1)
if echo "$CMD" | grep -qE 'git\s+rebase\s+(origin/|refs/heads/)?(main|master|production)(\s*$|\s*[;&|])' || \
   echo "$CMD" | grep -qE 'git\s+rebase\s+.*\s(origin/|refs/heads/)?(main|master|production)(\s*$|\s*[;&|])'; then
  echo "BLOCKED: Rebase on shared branch." >&2
  exit 2
fi

# --- Database destruction ---
if echo "$CMD" | grep -qiE 'DROP\s+(TABLE|DATABASE|SCHEMA)|TRUNCATE\s+TABLE'; then
  echo "BLOCKED: Destructive database operation." >&2
  exit 2
fi

# DELETE FROM without meaningful WHERE
if echo "$CMD" | grep -qiE 'DELETE\s+FROM\s+\w+\s*;' || \
   echo "$CMD" | grep -qiE 'DELETE\s+FROM\s+\w+\s*$' || \
   echo "$CMD" | grep -qiE 'DELETE\s+FROM\s+\w+\s+WHERE\s+(1\s*=\s*1|true)\b'; then
  echo "BLOCKED: DELETE without meaningful WHERE clause." >&2
  exit 2
fi

# Drizzle ORM destructive commands
if echo "$CMD" | grep -qE 'drizzle-kit\s+(drop|push\s+.*--force)'; then
  echo "BLOCKED: drizzle-kit destructive operation." >&2
  exit 2
fi

# --- Remote code execution ---
# curl/wget piped to shell
if echo "$CMD" | grep -qE '(curl|wget)\s+.*\|\s*(bash|sh|zsh)\b'; then
  echo "BLOCKED: Piping remote URL to shell." >&2
  exit 2
fi

# Download then execute pattern
if echo "$CMD" | grep -qE '(curl|wget)\s+.*-o\s+\S+.*&&.*\s(bash|sh|zsh|source)\s'; then
  echo "BLOCKED: Download-then-execute pattern." >&2
  exit 2
fi

# --- Package publishing ---
if echo "$CMD" | grep -qE '(npm|yarn|pnpm)\s+publish'; then
  echo "BLOCKED: Package publishing." >&2
  exit 2
fi

# --- System-wide package removal ---
if echo "$CMD" | grep -qE 'brew\s+uninstall|apt\s+remove|apt-get\s+remove|pip\s+uninstall'; then
  echo "BLOCKED: System package removal." >&2
  exit 2
fi

# --- chmod/chown on system paths ---
if echo "$CMD" | grep -qE '(chmod|chown)\s+.*(/?Users|/?home|/?System|/?Library|/?usr|/?bin|/?etc)\b'; then
  echo "BLOCKED: Permission change on system directory." >&2
  exit 2
fi

# --- Kill all / killall without specific target ---
if echo "$CMD" | grep -qE 'killall\s*$|kill\s+-9\s+-1'; then
  echo "BLOCKED: Mass process kill." >&2
  exit 2
fi

# --- Fork bomb ---
if echo "$CMD" | grep -qE ':\(\)\s*\{|:\s*\(\)\s*\{|\(\)\s*\{\s*\|.*&'; then
  echo "BLOCKED: Fork bomb pattern detected." >&2
  exit 2
fi

# --- Format/disk operations ---
if echo "$CMD" | grep -qE 'mkfs\.|diskutil\s+eraseDisk|dd\s+if=.*of=/dev/'; then
  echo "BLOCKED: Disk format/write operation." >&2
  exit 2
fi

exit 0
