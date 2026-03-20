# CC-Setup

My Claude Code setup - skills, hooks, status line, and settings config. Copy to `~/.claude/` on any device.

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

# Status Line
cp statusline/statusline.sh ~/.claude/statusline.sh
cp statusline/statusline-refresh.sh ~/.claude/statusline-refresh.sh
```

### 2. Add to `~/.claude/settings.json`

Add hooks and status line config (merge with any existing settings):

```json
"hooks": {
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
},
"statusLine": {
  "type": "command",
  "command": "bash $HOME/.claude/statusline.sh",
  "padding": 0
}
```

### 3. Dependencies

Make sure `jq` is installed (used by the hook script and status line):

```bash
# macOS
brew install jq

# WSL/Linux
sudo apt install jq

# ccusage (needed for block timer in status line)
npm install -g ccusage
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

### Status Line

Custom status bar displayed below the input box. Shows at a glance:

```
◆ Opus 4.6 │ 300K/1M ▐██████░░░░░░░░░░░░░░▌ 30% │ ⏱ 35m
```

| Section        | Source                 | Details                                                             |
| -------------- | ---------------------- | ------------------------------------------------------------------- |
| Model name     | Claude Code JSON stdin | Dynamic - adapts to any model (Opus, Sonnet, Haiku, etc.)           |
| Context window | Claude Code JSON stdin | Shows used/max (e.g. 300K/1M, 150K/200K) - fully dynamic           |
| Context % bar  | Claude Code JSON stdin | Color-coded progress bar: green (<50%), yellow (50-80%), red (>80%) |
| Block timer    | ccusage (cached)       | 5-hour usage block countdown: green (>2h), yellow (>30m), red      |

**How it works:**

- `statusline.sh` - fast renderer (<50ms), parses JSON + reads cache, runs on every status update
- `statusline-refresh.sh` - background worker, calls ccusage every ~5min to refresh block timer cache
- No API tokens consumed, fully local

---

## Credits

- Review skill includes patterns from [agent-pr](https://github.com/ijw-fyi/agent-pr)
