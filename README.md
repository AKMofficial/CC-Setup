# CC-Setup

My Claude Code setup - skills, hooks, status line, and settings config. Copy to `~/.claude/` on any device.

## Setup

### 1. Copy files

```bash
# Skills
mkdir -p ~/.claude/skills/commit ~/.claude/skills/verify ~/.claude/skills/review ~/.claude/skills/cursor-implement ~/.claude/skills/codex-implement ~/.claude/skills/opencode-implement
cp skills/commit/SKILL.md ~/.claude/skills/commit/SKILL.md
cp skills/verify/SKILL.md ~/.claude/skills/verify/SKILL.md
cp skills/review/SKILL.md ~/.claude/skills/review/SKILL.md
cp skills/cursor-implement/SKILL.md ~/.claude/skills/cursor-implement/SKILL.md
cp skills/codex-implement/SKILL.md ~/.claude/skills/codex-implement/SKILL.md
cp skills/opencode-implement/SKILL.md ~/.claude/skills/opencode-implement/SKILL.md

# Hooks
mkdir -p ~/.claude/hooks
cp hooks/block-dangerous-commands.sh ~/.claude/hooks/block-dangerous-commands.sh
cp hooks/block-worktrees.sh ~/.claude/hooks/block-worktrees.sh
cp hooks/notify-stop-sound.sh ~/.claude/hooks/notify-stop-sound.sh
chmod +x ~/.claude/hooks/block-dangerous-commands.sh ~/.claude/hooks/block-worktrees.sh ~/.claude/hooks/notify-stop-sound.sh

# Status Line
cp statusline/statusline.sh ~/.claude/statusline.sh
cp statusline/statusline-refresh.sh ~/.claude/statusline-refresh.sh
```

### 2. Add to `~/.claude/settings.json`

Add hooks and status line config (merge with any existing settings):

```json
"cleanupPeriodDays": 99999,
"env": {
  "CLAUDE_AFK_TIMEOUT_MS": "2147483647"
},
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
  ],
  "Stop": [
    {
      "matcher": "",
      "hooks": [
        {
          "type": "command",
          "command": "$HOME/.claude/hooks/notify-stop-sound.sh"
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

- `cleanupPeriodDays: 99999` keeps chat transcripts/session data effectively forever (~273 years). Claude Code auto-deletes session files older than this on startup; the default is only 30 days and there is no "never" value, so a large number is the supported way to retain history. [Docs](https://code.claude.com/docs/en/settings)
- `env.CLAUDE_AFK_TIMEOUT_MS` (≈ max int) disables the AFK/idle timeout, so long-running prompts (e.g. `AskUserQuestion`) don't time out.
- The `Stop` hook runs `notify-stop-sound.sh`, which plays a sound when Claude finishes a turn — but **only in the main chat**, staying silent when a background subagent/Agent-tool task completes (it reads the hook's JSON stdin and skips the sound when an `agent_id` is present). macOS `afplay`; swap the command inside the script on Linux/WSL.
- `worktree.bgIsolation: "none"` is required alongside the worktree hook: the hook blocks *explicit* worktree tool calls, but the harness's automatic background-isolation worktree is governed only by this setting.

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
| **codex-implement** | `/codex-implement <what to build>` | Same spec-author/reviewer loop, but delegates coding to OpenAI's Codex CLI (`codex exec`), using whatever default model/effort is saved in `~/.codex/config.toml` (set via `/model` in Codex). Requires `codex` installed and authenticated. |
| **opencode-implement** | `/opencode-implement <what to build>` | Same spec-author/reviewer loop, but delegates coding to opencode's headless CLI (`opencode run`), using whatever model is currently selected in opencode. Requires `opencode` installed and authenticated. |

**Recommended workflow:** `/simplify` (built-in - cleans up code) then `/verify` to confirm cleanup is safe, then `/review` before committing.

### Hooks

| Hook                         | Event             | What it blocks                                                                                                                                                          |
| ---------------------------- | ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **block-dangerous-commands** | PreToolUse (Bash) | sudo, doas, eval, rm on system/home dirs, git add/commit (user controls staging and commits), git force push/reset/clean/restore/rebase, DROP/TRUNCATE/DELETE, curl pipe to shell, npm publish, fork bombs, disk format ops |
| **block-worktrees** | PreToolUse (Agent, EnterWorktree, Bash) | All git worktree creation — `EnterWorktree` tool, Agent `isolation: "worktree"`, and `git worktree add` (allows list/remove/prune). Pair with `worktree.bgIsolation: "none"` in settings to also stop automatic background-isolation worktrees. |
| **notify-stop-sound** | Stop | Plays a sound when Claude finishes a turn, but only in the main chat — silent for background subagents (skips when the hook payload carries an `agent_id`). |

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
