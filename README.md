# CC-Setup

My Claude Code setup - skills, hooks, status line, and settings config. Copy to `~/.claude/` on any device.

## Setup

### 1. Copy files

```bash
# Skills
mkdir -p ~/.claude/skills/commit ~/.claude/skills/verify ~/.claude/skills/qa ~/.claude/skills/spec ~/.claude/skills/implement
cp skills/commit/SKILL.md ~/.claude/skills/commit/SKILL.md
cp skills/verify/SKILL.md ~/.claude/skills/verify/SKILL.md
cp skills/qa/SKILL.md ~/.claude/skills/qa/SKILL.md
cp skills/spec/SKILL.md ~/.claude/skills/spec/SKILL.md
cp skills/implement/SKILL.md ~/.claude/skills/implement/SKILL.md

# Hooks
mkdir -p ~/.claude/hooks
cp hooks/block-dangerous-commands.sh ~/.claude/hooks/block-dangerous-commands.sh
cp hooks/block-worktrees.sh ~/.claude/hooks/block-worktrees.sh
cp hooks/notify-stop-sound.sh ~/.claude/hooks/notify-stop-sound.sh
cp hooks/block-em-dashes.sh ~/.claude/hooks/block-em-dashes.sh
chmod +x ~/.claude/hooks/block-dangerous-commands.sh ~/.claude/hooks/block-worktrees.sh ~/.claude/hooks/notify-stop-sound.sh ~/.claude/hooks/block-em-dashes.sh

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
    },
    {
      "matcher": "Write|Edit|MultiEdit|NotebookEdit|Bash|PowerShell",
      "hooks": [
        {
          "type": "command",
          "command": "$HOME/.claude/hooks/block-em-dashes.sh"
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
- The `Stop` hook runs `notify-stop-sound.sh`, which plays a sound when Claude finishes a turn, but **only in the main chat**, staying silent when a background subagent/Agent-tool task completes (it reads the hook's JSON stdin and skips the sound when an `agent_id` is present). macOS `afplay`; swap the command inside the script on Linux/WSL.
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
| **commit** | `/commit` | Reads staged changes, writes a changelog-style commit message (sized to the change) to `COMMIT_MESSAGE.md` |
| **verify** | `/verify` | Reviews unstaged changes - reports if they're safe, worth staging, or break something |
| **qa** | `/qa [staged\|unstaged] <the feature request>` | Feature review of changes (e.g. written by another AI agent) against what was asked - checks every requirement is done, finds bugs and missed places, checks it matches the project's style/UI and is light and fast, researches known pitfalls on the web, and lists unrelated changes in the diff neutrally |
| **spec** | `/spec <the rough idea>` | Turns a vague feature request into a full spec: researches the codebase and the web, asks only the real product decisions in batches of up to 4, then writes `specs/<feature>.md` with flows, every affected place, edge cases, approach, open stakeholder questions, and acceptance criteria |
| **implement** | `/implement [codex\|cursor\|opencode][:model] <what to build>` | Delegates coding to another AI CLI (Codex, Cursor, or opencode) while Claude writes the spec, reviews the diff, and loops until every gate is green. Default tool and per-tool models are set in the skill's Config block; pick another per run with e.g. `/implement cursor ...` or `/implement codex:gpt-5.5 ...`. Starts a fresh implementer session when one gets long or slow. Requires the chosen CLI installed and authenticated. |

**Feature workflow:** `/spec` to turn a vague request into a spec, then `/implement specs/<feature>.md` to build it, then `/qa staged <the request>` to check it against the spec.

**Cleanup workflow:** `/simplify` (built-in - cleans up code) then `/verify` to confirm cleanup is safe, then `/code-review` (built-in) before committing. Add `/security-review` (built-in) when a change touches auth, user input, or data.

### Hooks

| Hook                         | Event             | What it blocks                                                                                                                                                          |
| ---------------------------- | ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **block-dangerous-commands** | PreToolUse (Bash) | sudo, doas, eval, rm on system/home dirs, git add/commit (user controls staging and commits), git force push/reset/clean/restore/rebase, DROP/TRUNCATE/DELETE, curl pipe to shell, npm publish, fork bombs, disk format ops |
| **block-worktrees** | PreToolUse (Agent, EnterWorktree, Bash) | All git worktree creation: `EnterWorktree` tool, Agent `isolation: "worktree"`, and `git worktree add` (allows list/remove/prune). Pair with `worktree.bgIsolation: "none"` in settings to also stop automatic background-isolation worktrees. |
| **notify-stop-sound** | Stop | Plays a sound when Claude finishes a turn, but only in the main chat; silent for background subagents (skips when the hook payload carries an `agent_id`). |
| **block-em-dashes** | PreToolUse (Write, Edit, MultiEdit, NotebookEdit, Bash, PowerShell) | Any em dash, en dash, or lookalike (figure dash, horizontal bar, two/three-em dash, small em dash, vertical dashes) or HTML entity that renders as one (named `mdash`/`ndash` entities or numeric ones like decimal 8212 and hex x2014) written into a file. Checks only the new text, so files with existing dashes can still be edited. Shell commands containing a dash are blocked unless every part is a read-only search (`grep`, `rg`, `find` without `-exec`, `git log/show/diff/grep`...) with no redirect, `tee`, heredoc, or other write. Tells Claude to use a comma, colon, semicolon, parentheses, a period, or a plain hyphen instead. Doesn't see files written by other tools (e.g. Codex/Cursor/opencode via `/implement`). |

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

- `/spec` borrows ideas (no code or text) from Matt Pocock's [grill-me](https://skillselion.com/skills/mattpocock/skills/grill-me) skill and GitHub [spec-kit](https://github.com/github/spec-kit)'s `/clarify` command
