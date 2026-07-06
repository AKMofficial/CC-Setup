# CC-Setup

My Claude Code setup - skills, hooks, status line, and settings config. Copy to `~/.claude/` on any device.

## Setup

### 1. Copy files

```bash
# Skills
mkdir -p ~/.claude/skills/commit ~/.claude/skills/verify ~/.claude/skills/review ~/.claude/skills/cursor-implement ~/.claude/skills/codex-implement
cp skills/commit/SKILL.md ~/.claude/skills/commit/SKILL.md
cp skills/verify/SKILL.md ~/.claude/skills/verify/SKILL.md
cp skills/review/SKILL.md ~/.claude/skills/review/SKILL.md
cp skills/cursor-implement/SKILL.md ~/.claude/skills/cursor-implement/SKILL.md
cp skills/codex-implement/SKILL.md ~/.claude/skills/codex-implement/SKILL.md

# Hooks
mkdir -p ~/.claude/hooks
cp hooks/block-dangerous-commands.sh ~/.claude/hooks/block-dangerous-commands.sh
cp hooks/block-worktrees.sh ~/.claude/hooks/block-worktrees.sh
chmod +x ~/.claude/hooks/block-dangerous-commands.sh ~/.claude/hooks/block-worktrees.sh

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
    },
    {
      "matcher": "Agent|EnterWorktree|Bash",
      "hooks": [
        {
          "type": "command",
          "command": "$HOME/.claude/hooks/block-worktrees.sh"
        }
      ]
    }
  ]
},
"worktree": {
  "bgIsolation": "none"
},
"statusLine": {
  "type": "command",
  "command": "bash $HOME/.claude/statusline.sh",
  "padding": 0
}
```

The `worktree.bgIsolation: "none"` setting is required alongside the hook: the hook blocks *explicit* worktree tool calls, but the harness's automatic background-isolation worktree is governed only by this setting.

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
| **cursor-implement** | `/cursor-implement <what to build>` | Delegates coding to Cursor's headless agent (`cursor-agent`, `composer-2.5-fast`) while Claude writes the spec, reviews the diff, and loops until every gate is green. Requires `cursor-agent` installed and authenticated. |
| **codex-implement** | `/codex-implement <what to build>` | Same spec-author/reviewer loop, but delegates coding to OpenAI's Codex CLI (`codex exec`, `gpt-5.5` at medium reasoning). Requires `codex` installed and authenticated. |

**Recommended workflow:** `/simplify` (built-in - cleans up code) then `/verify` to confirm cleanup is safe, then `/review` before committing.

### Hooks

| Hook                         | Event             | What it blocks                                                                                                                                                          |
| ---------------------------- | ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **block-dangerous-commands** | PreToolUse (Bash) | sudo, doas, eval, rm on system/home dirs, git force push/reset/clean/restore/rebase, DROP/TRUNCATE/DELETE, curl pipe to shell, npm publish, fork bombs, disk format ops |
| **block-worktrees** | PreToolUse (Agent, EnterWorktree, Bash) | All git worktree creation — `EnterWorktree` tool, Agent `isolation: "worktree"`, and `git worktree add` (allows list/remove/prune). Pair with `worktree.bgIsolation: "none"` in settings to also stop automatic background-isolation worktrees. |

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
