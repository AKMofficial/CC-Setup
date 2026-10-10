# CC-Setup

My Claude Code setup - skills, hooks, status line, and settings config. Copy to `~/.claude/` on any device.

## Setup

### 1. Copy files

```bash
# Skills
mkdir -p ~/.claude/skills/commit ~/.claude/skills/verify ~/.claude/skills/qa ~/.claude/skills/spec ~/.claude/skills/implement ~/.claude/skills/explain
cp skills/commit/SKILL.md ~/.claude/skills/commit/SKILL.md
cp skills/verify/SKILL.md ~/.claude/skills/verify/SKILL.md
cp skills/qa/SKILL.md ~/.claude/skills/qa/SKILL.md
cp skills/spec/SKILL.md ~/.claude/skills/spec/SKILL.md
cp skills/implement/SKILL.md ~/.claude/skills/implement/SKILL.md
cp skills/explain/SKILL.md ~/.claude/skills/explain/SKILL.md

# Hooks
mkdir -p ~/.claude/hooks
cp hooks/block-dangerous-commands.sh ~/.claude/hooks/block-dangerous-commands.sh
cp hooks/block-worktrees.sh ~/.claude/hooks/block-worktrees.sh
cp hooks/notify-stop-sound.sh ~/.claude/hooks/notify-stop-sound.sh
cp hooks/block-em-dashes.sh ~/.claude/hooks/block-em-dashes.sh
chmod +x ~/.claude/hooks/block-dangerous-commands.sh ~/.claude/hooks/block-worktrees.sh ~/.claude/hooks/notify-stop-sound.sh ~/.claude/hooks/block-em-dashes.sh

# Status Line
cp statusline/statusline.sh ~/.claude/statusline.sh
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
      "matcher": "Bash|PowerShell",
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
  "padding": 0,
  "refreshInterval": 60
}
```

- `cleanupPeriodDays: 99999` keeps chat transcripts/session data effectively forever (~273 years). Claude Code auto-deletes session files older than this on startup; the default is only 30 days and there is no "never" value, so a large number is the supported way to retain history. [Docs](https://code.claude.com/docs/en/settings)
- `env.CLAUDE_AFK_TIMEOUT_MS` (≈ max int) disables the AFK/idle timeout, so long-running prompts (e.g. `AskUserQuestion`) do not time out.
- The `Stop` hook runs `notify-stop-sound.sh`, which plays a sound when Claude finishes a turn, but **only in the main chat**, staying silent when a background subagent/Agent-tool task completes (it reads the JSON stdin of the hook and skips the sound when an `agent_id` is present). macOS `afplay`; swap the command inside the script on Linux/WSL.
- `worktree.bgIsolation: "none"` is required alongside the worktree hook: the hook blocks *explicit* worktree tool calls, but the automatic background-isolation worktree of the harness is governed only by this setting.

### 3. Dependencies

Make sure `jq` is installed (used by the hook script and status line):

```bash
# macOS
brew install jq

# WSL/Linux
sudo apt install jq

```

### 4. Restart Claude Code

---

## What is included

### Skills

| Skill      | Command   | What it does                                                                          |
| ---------- | --------- | ------------------------------------------------------------------------------------- |
| **commit** | `/commit` | Reads staged changes, writes a changelog-style commit message (sized to the change) to `COMMIT_MESSAGE.md` |
| **verify** | `/verify` | Reviews unstaged changes - reports if they are safe, worth staging, or break something |
| **explain** | `/explain [staged\|unstaged\|all\|<commit>\|<base>..<head>\|#PR] [engineer\|simple] [--worth] [brief] [focus]` | Explains a change so you understand all of it: a short summary, then every change as its own self-contained block grouped by area (a plain heading, Before with the exact trigger, After with the real numbers and limits). No vague table cells and no separate walkthrough to cross-check. Two modes: `engineer` (default, adds file locations, key code and ripple effects) and `simple` (plain language for a non-technical reader). `--worth` adds a Keep / Drop / Your call verdict to every change, plus the small issues to fix before committing. Also lists deploy steps (env vars, migrations, deploy order). `brief` keeps only the main changes. Big diffs are split by area across parallel agents. Read-only. |
| **qa** | `/qa [staged\|unstaged] <the feature request>` | Feature review of changes (e.g. written by another AI agent) against what was asked - checks every requirement is done, finds bugs and missed places, checks it matches the style/UI of the project and is light and fast, researches known pitfalls on the web, and lists unrelated changes in the diff neutrally |
| **spec** | `/spec <the rough idea>` | Turns a vague feature request into a full spec: researches the codebase and the web, asks only the real product decisions in batches of up to 4, then writes `specs/<feature>.md` with flows, every affected place, edge cases, approach, open stakeholder questions, and acceptance criteria |
| **implement** | `/implement [codex\|cursor\|opencode][:model] <what to build>` | Delegates coding to another AI CLI (Codex, Cursor, or opencode) while Claude writes the spec, reviews the diff, and loops until every gate is green. Default tool and per-tool models are set in the Config block of the skill; pick another per run with e.g. `/implement cursor ...` or `/implement codex:gpt-5.5 ...`. Starts a fresh implementer session when one gets long or slow. Requires the chosen CLI installed and authenticated. |

**Feature workflow:** `/spec` to turn a vague request into a spec, then `/implement specs/<feature>.md` to build it, then `/qa staged <the request>` to check it against the spec.

**Cleanup workflow:** `/simplify` (built-in - cleans up code) then `/verify` to confirm cleanup is safe, then `/code-review` (built-in) before committing. Add `/security-review` (built-in) when a change touches auth, user input, or data.

### Hooks

| Hook                         | Event             | What it blocks                                                                                                                                                          |
| ---------------------------- | ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **block-dangerous-commands** | PreToolUse (Bash, PowerShell) | Destructive commands on macOS, Linux and Windows: deletes outside the project or temp dirs, risky git operations (reset, clean, force push, history rewrites), disk/system wipes, destructive SQL, and cloud/infra deletes. Fails closed: if it cannot tell what a command will do, it blocks it. Needs `jq`; on native Windows it needs Git Bash to run. |
| **block-worktrees** | PreToolUse (Agent, EnterWorktree, Bash) | All git worktree creation: `EnterWorktree` tool, Agent `isolation: "worktree"`, and `git worktree add` (allows list/remove/prune). Pair with `worktree.bgIsolation: "none"` in settings to also stop automatic background-isolation worktrees. |
| **notify-stop-sound** | Stop | Plays a sound when Claude finishes a turn, but only in the main chat; silent for background subagents (skips when the hook payload carries an `agent_id`). |
| **block-em-dashes** | PreToolUse (Write, Edit, MultiEdit, NotebookEdit, Bash, PowerShell) | Any em dash, en dash, or lookalike (figure dash, horizontal bar, two/three-em dash, small em dash, vertical dashes) or HTML entity that renders as one (named `mdash`/`ndash` entities or numeric ones like decimal 8212 and hex x2014) written into a file. Checks only the new text, so files with existing dashes can still be edited. Shell commands containing a dash are blocked unless every part is a read-only search (`grep`, `rg`, `find` without `-exec`, `git log/show/diff/grep`...) with no redirect, `tee`, heredoc, or other write. Tells Claude to use a comma, colon, semicolon, parentheses, a period, or a plain hyphen instead. Does not see files written by other tools (e.g. Codex/Cursor/opencode via `/implement`). |

> **Note:** I recommend running Claude Code in **auto mode** and treating `block-dangerous-commands` as an extra safety layer on top of it, not a replacement. It catches the common ways things go wrong, but it is a pattern filter, not a sandbox, so it cannot catch everything.

### Status Line

Custom status bar displayed below the input box. Shows at a glance:

```
◆ Opus 5.5 ⚡ (high) │ 300K/1M ▐██████░░░░░░░░░░░░░░▌ 30% (cache 4m) │ 5h 23% ↻ 2h14m │ 7d 41% ↻ 3d4h
```

| Section        | Source                 | Details                                                             |
| -------------- | ---------------------- | ------------------------------------------------------------------- |
| Model name     | Claude Code JSON stdin | Dynamic - adapts to any model (Opus, Sonnet, Haiku, etc.)           |
| Fast mode      | Claude Code JSON stdin | `⚡` after the model name, only while `/fast` is on |
| Effort level   | Claude Code JSON stdin | Reasoning effort in parentheses (low/medium/high/xhigh/max), updates live with `/effort`; hidden for models without effort support |
| Context window | Claude Code JSON stdin | Shows used/max (e.g. 300K/1M, 150K/200K) from exact token counts - fully dynamic |
| Context % bar  | Claude Code JSON stdin | Color-coded progress bar: green (<50%), yellow (50-80%), red (>80%) |
| Prompt cache   | Claude Code JSON stdin | Time until the prompt cache expires (yellow under 1m), or yellow `cold` once it has, shown in parentheses after the context %. A cold cache means the next message re-processes the whole conversation, which is slower and uses more of your plan limits. Hidden until the first response |
| 5h limit       | Claude Code JSON stdin | Plan usage in the 5-hour window (same colors, bold from 80%) and time until it resets |
| 7d limit       | Claude Code JSON stdin | Plan usage in the weekly window (same colors, bold from 80%) and time until it resets |

**How it works:**

- `statusline.sh` - fast renderer (~10ms, one `jq` call, no network), runs on every status update
- The 5h/7d limits come from the official `rate_limits` field (no ccusage or estimates). They only appear for claude.ai Pro/Max logins. A window drops out once it resets
- Limits are shared across sessions via `~/.claude/statusline-limits.json`. Each session only receives new limits on its own responses, so every session merges in what it saw and shows the freshest reading. With many sessions open, idle ones stay accurate, and a new session shows limits before its first message. The file is only rewritten when a session sees newer data
- `refreshInterval: 60` re-runs the script every minute so the reset countdowns stay current while the session is idle
- Fits the window: Claude Code passes the terminal width (`COLUMNS`), and when the full line does not fit, parts are dropped in this order instead of the end getting cut off: context bar, 7d countdown, 5h countdown, context tokens, cache, effort. The model, context %, and 5h/7d usage always stay. For example, in a narrow pane:
  ```
  ◆ Opus 5.5 ⚡ │ 8% │ 5h 24% │ 7d 41%
  ```
  After resizing a window, the line adjusts on the next update (at most a minute, via `refreshInterval`)
- No API tokens consumed, fully local

---

## Credits

- `/spec` borrows ideas (no code or text) from the [grill-me](https://skillselion.com/skills/mattpocock/skills/grill-me) skill by Matt Pocock and the `/clarify` command of GitHub [spec-kit](https://github.com/github/spec-kit)
- `/explain` borrows ideas (no code or text) from the [explain-diff](https://github.com/Chris-Graffagnino/explain-diff) skill by Chris Graffagnino (audience modes, removed-behavior audit, stated vs inferred intent, no invented sections), the [explain-diff](https://gist.github.com/geoffreylitt/a29df1b5f9865506e8952488eac3d524) prompt by Geoffrey Litt (toy-data examples, flow-ordered walkthrough), and the prlens [PR explanation guide](https://prlens.dev/guides/explain-a-pull-request-without-the-diff) (the "what does the system do now" TL;DR)
