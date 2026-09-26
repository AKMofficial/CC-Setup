---
name: implement
description: Implement a feature or fix by delegating the coding to another AI coding CLI (Codex, Cursor, or opencode, picked by config or per run, with an optional model) while Claude Code acts as spec author and reviewer. Claude writes a detailed spec, dispatches the implementer, reviews its diff against the project's own conventions, sends notes back into the implementer's session (starting a fresh one when the session gets long or slow), and loops until every gate is green and no notes remain. Auto-approves ONLY after rigorous verification that the plan is completely fulfilled. Use when the user says "/implement [tool[:model]] <what they want>" or asks to have Codex, Cursor, or opencode implement something with Claude reviewing.
argument-hint: "[codex|cursor|opencode[:model]] <what to build, or a spec file>"
---

# implement: another AI implements, Claude Code reviews & approves

You are the **orchestrator and reviewer**. An external coding CLI is the **implementer**. The user gives you a request; you drive the whole loop and only report back when the work is genuinely done and verified.

This skill is **project-agnostic**: it carries the loop and the review discipline, but the specific rules, patterns, and check commands come from whatever project it runs in. Learn them at step 0; do not assume any particular stack.

## Config

Edit these defaults to change what runs when the user doesn't say:

```yaml
default_tool: codex          # codex | cursor | opencode
models:                      # blank = use the tool's own saved default
  codex:                     # blank -> model/effort from ~/.codex/config.toml
  cursor: composer-2.5-fast  # cursor-agent needs an explicit model
  opencode:                  # blank -> whatever model is selected in opencode
```

## Parse the request

`$ARGUMENTS` is `[tool[:model]] <request>`. If it's empty, ask what to build and stop.

- If the first word is `codex`, `cursor`, or `opencode` (optionally followed by `:<model>`), that's the tool (and model) for this run; the rest is the request. Split on the first `:` only, so `opencode:anthropic/claude-sonnet-5` works.
  - `/implement add CSV export` uses the defaults above
  - `/implement cursor add CSV export` uses Cursor with its configured model
  - `/implement codex:gpt-5.5 add CSV export` uses Codex with that model
- Also honor overrides said in plain words ("use high effort", "use gpt-5 on cursor").
- If the request points at an existing spec file (e.g. `specs/<feature>.md` from `/spec`), use it as the source for your spec instead of re-deriving everything.

Say the tool and model you're using in one line before starting (e.g. `Implementer: cursor (composer-2.5-fast)`).

## Tools

Everything tool-specific lives here. The rest of the skill says "the implementer" and refers back to this table. `<M>` is the model; drop the model flag entirely when it's blank (except Cursor, which always needs one: if it's blank, ask the user). `<PROMPT>` is the dispatch prompt from step 2.

| | **codex** | **cursor** | **opencode** |
|---|---|---|---|
| New session | `codex exec --sandbox workspace-write [-m <M>] "<PROMPT>"` | `CHAT_ID=$(cursor-agent create-chat)` then `cursor-agent -p --force --trust --output-format text --model <M> --resume "$CHAT_ID" "<PROMPT>"` | `opencode run --title "<feature-slug>-s<N>" [-m <M>] "<PROMPT>"` |
| Session ID | printed in the run header as `session id: <uuid>` | the `CHAT_ID` you created | `opencode session list \| grep "<feature-slug>-s<N>"` |
| Continue session | `codex exec resume <id> -c sandbox_mode=workspace-write [-c model="<M>"] "<notes>"` | same as new session, with the same `--resume "$CHAT_ID"` | `opencode run -s <id> [-m <M>] "<notes>"` |
| Auto-loads rules | `AGENTS.md` only | `CLAUDE.md`, `AGENTS.md`, `.cursor/rules/` | `AGENTS.md` only |
| Reasoning effort | `-c model_reasoning_effort=<low\|medium\|high>` | pick a model variant | `--variant <effort>` where the provider supports it |
| Read-only / plan | `--sandbox read-only` (or `codex exec review`) | `--mode plan` | `--agent plan` |
| Login on auth error | `codex login` | `cursor-agent login` | `opencode auth login` |
| **Never use** | `-C`, `resume --last`, `--dangerously-bypass-approvals-and-sandbox` | `-w` / `--worktree`, `--continue`, bare `--resume` | `--dir`, `-c` / `--continue`, `--auto` |

Why the "never use" column: the implementer must run in the current tree so you review the exact diff the user sees, and must always be pinned to this run's own session ID (the "most recent session" flags can grab another run's session when several Claude sessions run in parallel). Codex's default sandbox is read-only, so it needs `workspace-write` to edit (`resume` has no `-s`, so it takes the sandbox and model via `-c`); that sandbox also blocks network and out-of-workspace writes, while `--dangerously-bypass-approvals-and-sandbox` removes all of it, so never use it. opencode's `--auto` approves permissions the user's config would gate: if a run stalls on a permission, stop and tell the user.

Continuing the same session keeps the loop cheap: the implementer keeps its context and you send only deltas (until it gets too long, see step 5).

Assume the tool is installed and logged in: don't pre-check auth, just dispatch. Only on an auth error, tell the user the login command and stop.

## Hard rules (never violate)

- **The implementer must not touch git** (commit, push, history); tell it so in every prompt. You review an uncommitted diff. **You don't commit either** (a hook blocks `git commit`; the user commits), and don't push unless the user asks after approval.
- **Don't run irreversible or externally-visible commands; leave those to the user.** Deploys / publishes, DB migrations / schema pushes / seeds, destructive SQL, and the like. If the change needs such a step to take effect, don't run it: note it as a **manual follow-up** and tell the implementer the same. (Codex's sandbox already blocks most of this; the rule covers the rest.)
- **Don't pick a model yourself.** Use the config or the user's override only. Whatever model runs may be strong or weak; you don't know, so review hard either way and iterate until the code is genuinely clean and correct. "It typechecks" is the floor, not the bar. With a fast/cheap model (like Cursor's `composer-2.5-fast`) expect a flawed first draft: it doesn't fill gaps with engineering judgment, it produces plausible completions.
- **Auto-approve only when the Approval gate checklist is fully met.** If anything is uncertain, stop and show the user the diff + your concerns.
- **The project's conventions apply even though another AI wrote the code**: you're accountable as if you wrote it.

## Step 0: Learn THIS project's rules (do this first, once)

Learn the project's non-negotiables and reusable utilities from its convention docs (`CLAUDE.md` / `AGENTS.md` / `README`), and note its **check commands** (typecheck / lint / test, from `package.json` scripts, `Makefile`, or language-native tools) for the step-4 gates. The implementer may not load those rule files itself (see "Auto-loads rules" in Tools), so put the task-relevant constraints into the spec (step 1); either way you'll verify it followed them. Keep the rules, reusables, and check commands handy: the spec, review, and gate steps refer back to them.

## The loop

**Fix-list, not a feature?** If the request is already concrete findings (`/code-review`, `/simplify`, a bug list), skip the PRD: write them as a numbered list to `./tmp/implement/<feature-slug>.md` (so a fresh session can pick them up too) and dispatch with that file as the task, then run the same review, gates, and loop. Write the full spec below only for open-ended features.

### 1. Author the spec (you, the reviewer)

The spec is the single biggest lever on how well the implementer does. Every ambiguity you leave becomes a plausible-but-wrong guess and another review round. Invest here.

First **read enough of the codebase to write with specifics, not hand-waving**: real file paths, real function names, real patterns. A spec that says "add validation" is worthless; one that names the existing validation schema/util to reuse and its path is executable.

**After you've checked the code, if anything is unclear, ask the user before writing the spec, even if it's 20 questions. Ask in batches.**

Write the spec as a PRD to `./tmp/implement/<feature-slug>.md`. **Never delete it; leave it for the user.** A file path beats a giant inline prompt, and it's what lets a fresh session pick up the work (see step 5).

- **Goal & why**: what's being built and the user need behind it, in a line.
- **Acceptance criteria**: numbered, deterministic, testable outcomes (input -> expected output where it matters). This is the contract you verify against at the end.
- **Edge cases**: list them explicitly (empty, permission-denied, invalid input, boundaries, concurrency, overflow, i18n). Unlisted = unhandled.
- **Design decisions**: make the design calls yourself before any code exists: file/module structure, interfaces and function signatures, data shapes, error-handling strategy. Record each decision with a one-line **why**. Anything you leave open, the implementer resolves with a plausible guess instead of your intent.
- **Files to touch**: the files you expect the implementer to create/modify, with real paths. Your scope checklist at review; if you can't predict one, say so.
- **Existing code to reuse**: the files/components/utilities to build on, with real paths (from step 0).
- **A concrete example**: one worked input -> expected output, where behavior is non-obvious.
- **Project constraints**: the mandatory rules this task is likely to trip; spell them out, since the implementer may not load the project's rule files itself. (Cursor loads them all, so for Cursor just call out the one or two this task is likely to trip.)
- **Out of scope**: what to leave alone, so the implementer doesn't widen scope.

Keep it at the right **altitude**: outcomes and the modules to change, not line-by-line pseudocode nor a vague one-liner. Break a large task into chunks you can verify one at a time.

Show the user a short summary (goal + acceptance criteria) before dispatching so they can course-correct early. Don't block on approval unless the request was genuinely ambiguous; proceed.

### 2. Dispatch the implementer (first round)

Start a **new session** (see Tools) with this prompt:

```text
Implement the spec (or fix list) in ./tmp/implement/<feature-slug>.md exactly. Follow every project constraint listed there.
Preserve unrelated user changes: touch only what this task needs. Do NOT edit global/system config.
Do NOT run irreversible or externally-visible commands: no deploys/publishes, no database migrations/pushes/seeds (drizzle-kit push/migrate, prisma migrate, etc.). If the change needs such a step to take effect, describe it in your summary instead of running it.
Leave ALL changes uncommitted in the working tree: do NOT run git commit, git push, git checkout, or create branches/worktrees.
When done, print a short summary of every file you changed, how each acceptance criterion is satisfied, and any manual follow-up commands the user must run themselves.
```

Record the session ID. Capture the printed output for context, but **do not trust it**: you review the real diff, not the implementer's self-report.

### 3. Review (you)

Do a genuine senior review of what the implementer actually did:

1. `git diff`: read every change. Cross-check touched files against the spec's **Files to touch**; anything extra is scope creep. **Undo only the implementer's own mistakes, and only when you're sure they're not the user's**: preserve unrelated user changes. If you can't cleanly separate them, or the repo's left worse, stop and report with the diff summary instead of fixing it yourself.
2. **Replicate the project's guardrails by hand**: linters/formatters/hooks don't fire on the implementer's edits. Check the diff obeys each mandatory rule (naming, forbidden APIs, no `eslint-disable` / `@ts-ignore` / `# noqa` unless the project sanctions it).
3. **Check the project's invariants** a compiler won't catch: auth/permission checks, logging/audit, data-access filters, i18n, safe queries.
4. **Verify each acceptance criterion** is actually implemented, not gestured at.
5. **Watch for model mistakes**: hallucinated imports/paths, half-done edits, dead code, abandoned files, scope creep.
6. **Audit tests**: if the implementer wrote or touched tests, check it didn't game them: hardcoded expected outputs, weakened assertions, skipped/deleted tests.

Produce a **numbered notes list**: each note is a concrete, actionable defect with the file:line and what's wrong. Rank by severity so the worst gets fixed first, but **every note must be resolved before approval, minor and polish ones included, not just the critical ones.**

### 4. Run the gates

Run **this project's own** typecheck, lint, and test commands (identified in step 0), on the side(s) the diff touches. Examples of what that looks like across stacks:

```bash
# JS/TS       tsc --noEmit  ·  eslint .  ·  npm test
# Python      mypy .  ·  ruff check .  ·  pytest
# Rust        cargo check  ·  cargo clippy  ·  cargo test
# Go          go vet ./...  ·  go test ./...
```

Use the actual scripts the project defines (e.g. a `package.json` "typecheck"/"lint"/"test" script or a `Makefile` target) rather than guessing flags. Any failure is automatically a note (paste the error).

### 5. Send notes back (same session, or a fresh one when it's gotten long)

If there are any notes at all, **continue the implementer's session** (see Tools) so it keeps its context:

```text
Review notes to address. Fix each, keep changes uncommitted, don't touch git.
1. <note>
2. <note>
...
```

**Start a fresh session when the current one has run long.** Long sessions get slower and sloppier: each round re-reads a growing history, and the model starts forgetting constraints from the spec. You have the spec file and the diff, so a new session loses nothing that matters. Switch when any of these is true:

- the session has already had ~3 rounds,
- a round takes clearly longer than the earlier ones for a similar amount of work,
- the implementer repeats a mistake you already flagged, undoes an earlier fix, or ignores a spec constraint it followed before,
- you're moving on to the next chunk of a large task (each chunk can start clean).

For a fresh session, start a **new session** (see Tools; for opencode bump the title to `<feature-slug>-s2`, `-s3`, ...), record its new ID, and use this handoff prompt:

```text
You're continuing work another session started. The spec (or fix list) is ./tmp/implement/<feature-slug>.md: read it first and follow every project constraint in it.
The work so far is already in the working tree, uncommitted (run git diff to see it). Keep what's correct; don't start over.
Address these outstanding review notes:
1. <note>
2. <note>
...
Same rules as before: preserve unrelated user changes, no irreversible/externally-visible commands, don't touch git.
When done, print a short summary of every file you changed and how each note is resolved.
```

Then go back to **step 3**. Repeat the review, gates, notes cycle until:
- all acceptance criteria are met,
- all gates pass,
- **no notes remain at all, every one, however minor.**

Cap at ~6 rounds total (across all sessions). If the implementer still loops or regresses after a fresh session, STOP and report what's stuck and which files (with the diff summary); don't burn rounds. The revert rule from step 3 applies: undo only the implementer's mistakes, never the user's work.

## Approval gate (auto-approve criteria)

The user chose **auto-approve on green**, but only with rigorous verification. Auto-approve is permitted **only when ALL of these are simultaneously true**:

- [ ] Every numbered acceptance criterion from the spec is implemented and you verified it in the actual diff (not from the implementer's summary).
- [ ] Every gate passes: the project's typecheck, lint, and tests are all clean on every touched side.
- [ ] **No notes remain at all**: every note from review is fixed, even minimal/polish ones; all of the project's mandatory rules and invariants (step 0) hold.
- [ ] The change is complete end-to-end: no TODOs, stubs, dead code, half-wired features, or unhandled edge cases from the spec.
- [ ] Scope matches the spec: nothing unrelated was changed or deleted.

If every box is checked, **approve** and report to the user (see below). Leave changes uncommitted for them to commit.

If any box is **not** checkable with confidence, do NOT auto-approve. Stop, show the user the diff summary, the exact box(es) you couldn't check, and your remaining concern, and ask how to proceed.

## Reporting back

When done (approved or stopped), give the user:
- **Implementer**: tool and model used.
- **What was built**: one paragraph.
- **Acceptance criteria**: the checklist with ✓/✗ each.
- **Rounds**: how many iterations it took, how many sessions (and why you started fresh ones), and the gist of what you sent back.
- **Gate results**: typecheck/lint/test status.
- **Files changed**: from `git diff --stat`.
- **Manual follow-ups**: any side-effecting commands the change needs that you deliberately did NOT run (DB migration/push, dependency install, deploy, etc.), spelled out for the user to run themselves. Say "none" if there are none.
- **Verdict**: approved (and "ready to commit"), or stopped-with-concerns.
