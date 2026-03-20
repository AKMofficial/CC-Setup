# CC-Setup

My Claude Code setup - skills, hooks, and settings config. Copy to `~/.claude/` on any device.

## Setup

### 1. Copy files

```bash
# Skills
mkdir -p ~/.claude/skills/commit ~/.claude/skills/verify ~/.claude/skills/review
cp skills/commit/SKILL.md ~/.claude/skills/commit/SKILL.md
cp skills/verify/SKILL.md ~/.claude/skills/verify/SKILL.md
cp skills/review/SKILL.md ~/.claude/skills/review/SKILL.md

# Hooks
mkdir -p ~/.claude/hooks
cp hooks/block-dangerous-commands.sh ~/.claude/hooks/block-dangerous-commands.sh
chmod +x ~/.claude/hooks/block-dangerous-commands.sh
```

### 2. Add hooks to `~/.claude/settings.json`

Add this inside your `"hooks"` key (merge with any existing hooks):

```json
"PreToolUse": [
  {
    "matcher": "Bash",
    "hooks": [
      {
        "type": "command",
        "command": "$HOME/.claude/hooks/block-dangerous-commands.sh"
      }
    ]
  }
]
```

### 3. Dependencies

Make sure `jq` is installed (used by the hook script):

```bash
# macOS
brew install jq

# WSL/Linux
sudo apt install jq
```

### 4. Restart Claude Code

---

## What's included

### Skills

| Skill      | Command   | What it does                                                                          |
| ---------- | --------- | ------------------------------------------------------------------------------------- |
| **commit** | `/commit` | Reads staged changes, writes a conventional commit message to `COMMIT_MESSAGE.md`     |
| **review** | `/review` | Full code review on uncommitted changes - bugs, security, types, logic, performance   |
| **verify** | `/verify` | Reviews unstaged changes - reports if they're safe, worth staging, or break something |

**Recommended workflow:** `/simplify` (built-in - cleans up code) then `/verify` to confirm cleanup is safe, then `/review` before committing.

### Hooks

| Hook                         | Event             | What it blocks                                                                                                                                                          |
| ---------------------------- | ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **block-dangerous-commands** | PreToolUse (Bash) | sudo, doas, eval, rm on system/home dirs, git force push/reset/clean/restore/rebase, DROP/TRUNCATE/DELETE, curl pipe to shell, npm publish, fork bombs, disk format ops |
