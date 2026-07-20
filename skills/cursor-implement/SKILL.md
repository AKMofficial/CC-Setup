---
name: cursor-implement
description: Implement a feature or fix by delegating the coding to Cursor's headless agent (cursor-agent, model composer-2.5-fast) while Claude Code acts as spec author and reviewer. Claude writes a detailed spec, dispatches Cursor to implement, reviews Cursor's diff against the project's own conventions, sends notes back into the SAME Cursor session, and loops until every gate is green. Auto-approves ONLY after rigorous verification that the plan is completely fulfilled. Use when the user says "/cursor-implement <what they want>" or asks to have Cursor implement something with Claude reviewing.
---

# cursor-implement — Cursor implements, Claude Code reviews & approves

You are the **orchestrator and reviewer**. Cursor's headless CLI (`cursor-agent`) is the **implementer**. The user gives you a request; you drive the whole loop and only report back when the work is genuinely done and verified.

This skill is **project-agnostic** — it carries the loop and the review discipline, but the specific rules, patterns, and check commands come from whatever project it runs in. Learn them at step 0; do not assume any particular stack.

The user's request is in `$ARGUMENTS`. If it's empty, ask what to build and stop.

## Hard rules (never violate)

- **Never pass `-w` / `--worktree` to cursor-agent** — Cursor works in the current tree so you review the exact diff the user sees.
- **Cursor must not touch git** (commit, push, history) — tell it so in the dispatch prompt; you review an uncommitted diff. **You don't commit or push either**, unless the user asks after approval.
- **Don't run irreversible or externally-visible commands — leave those to the user.** Deploys / publishes, DB migrations / schema pushes / seeds, destructive SQL, and the like. If the change needs such a step to take effect, don't run it — note it as a **manual follow-up** and tell Cursor the same.
- **Model is fixed: `composer-2.5-fast`** unless the user overrides it. It's fast and cheap, so expect a flawed first draft — review hard and iterate until the code is genuinely clean and correct. "It typechecks" is the floor, not the bar.
- **Auto-approve only when the Approval gate checklist is fully met.** If anything is uncertain, stop and show the user the diff + your concerns.
- **The project's conventions apply even though Cursor wrote the code** — you're accountable as if you wrote it.

## Step 0 — Learn THIS project's rules (do this first, once)

Cursor auto-loads the project's rule files (`CLAUDE.md` / `AGENTS.md` / `.cursor/rules/`), so you don't feed rules to Cursor — you learn them to **verify Cursor followed them** (a fast model often won't) and to know what to reuse. Skim the convention docs for the non-negotiables, note the project's **check commands** (typecheck / lint / test — from `package.json` scripts, `Makefile`, or language-native tools) for the step-4 gates, and glance at neighboring code. Keep these handy — the review and gate steps refer back to them.

## The loop

**Fix-list, not a feature?** If the request is already concrete findings (`/code-review`, `/simplify`, a bug list), skip the PRD — pass them to Cursor inline as the task (numbered), then run the same review → gates → loop. Write the full spec below only for open-ended features.

### 1. Author the spec (you, the reviewer)

The spec is the single biggest lever on how well Cursor does. A fast model like `composer-2.5-fast` **does not fill gaps with engineering judgment — it produces statistically plausible completions**. Every ambiguity you leave becomes a wrong guess and another review round. Invest here.

First **read enough of the codebase to write with specifics, not hand-waving** — real file paths, real function names, real patterns. A spec that says "add validation" is worthless; one that names the existing validation schema/util to reuse and its path is executable.

**After you've checked the code, if anything is unclear, ask the user before writing the spec — even if it's 20 questions. Make it in batches.**

Write the spec as a PRD to `./tmp/cursor-implement/<feature-slug>.md`. **Never delete it — leave it for the user.** A file path beats a giant inline prompt.

- **Goal & why** — what's being built and the user need behind it, in a line.
- **Acceptance criteria** — numbered, deterministic, testable outcomes (input → expected output where it matters). This is the contract you verify against at the end.
- **Edge cases** — list them explicitly (empty, permission-denied, invalid input, boundaries, concurrency, overflow, i18n). Unlisted = unhandled.
- **Design decisions** — make the design calls yourself before any code exists: file/module structure, interfaces and function signatures, data shapes, error-handling strategy. Record each decision with a one-line **why**. Anything you leave open, the implementer decides by statistical guess — the spec should leave nothing to interpret.
- **Files to touch** — the files you expect the implementer to create/modify, with real paths. Your scope checklist at review; if you can't predict one, say so.
- **Existing code to reuse** — the files/components/utilities to build on, with real paths (from step 0).
- **A concrete example** — one worked input → expected output, where behavior is non-obvious.
- **Project constraints (only the risky ones)** — the implementer already has the rulebook; call out just the one or two rules this task is likely to trip. Skip if none.
- **Out of scope** — what to leave alone, so the implementer doesn't widen scope.

Keep it at the right **altitude**: outcomes and the modules to change, not line-by-line pseudocode nor a vague one-liner. Break a large task into chunks you can verify one at a time.

Show the user a short summary (goal + acceptance criteria) before dispatching so they can course-correct early. Don't block on approval unless the request was genuinely ambiguous — proceed.

### 2. Dispatch Cursor (first round)

First create a dedicated chat for this run — every round uses its ID via `--resume`:

```bash
CHAT_ID=$(cursor-agent create-chat)
```

```bash
cursor-agent -p --force --trust --output-format text --model composer-2.5-fast --resume "<chat-id>" \
  "Implement the spec in ./tmp/cursor-implement/<feature-slug>.md exactly. Follow every project constraint listed there. \
Preserve unrelated user changes — touch only what this task needs. Do NOT edit global/system config. \
Do NOT run irreversible or externally-visible commands — no deploys/publishes, no database migrations/pushes/seeds (drizzle-kit push/migrate, prisma migrate, etc.). If the change needs such a step to take effect, describe it in your summary instead of running it. \
Leave ALL changes uncommitted in the working tree — do NOT run git commit, git push, git checkout, or create branches/worktrees. \
When done, print a short summary of every file you changed, how each acceptance criterion is satisfied, and any manual follow-up commands the user must run themselves."
```

Capture Cursor's printed output for context, but **do not trust it** — you review the real diff, not Cursor's self-report.

### 3. Review (you)

Do a genuine senior review of what Cursor actually did:

1. `git diff` — read every change. Cross-check touched files against the spec's **Files to touch**; anything extra is scope creep. **Undo only Cursor's own mistakes, and only when you're sure they're not the user's** — preserve unrelated user changes. If you can't cleanly separate them, or the repo's left worse, stop and report with the diff summary instead of fixing it yourself.
2. **Replicate the project's guardrails by hand** — linters/formatters/hooks don't fire on Cursor's edits. Check the diff obeys each mandatory rule (naming, forbidden APIs, no `eslint-disable` / `@ts-ignore` / `# noqa` unless the project sanctions it).
3. **Check the project's invariants** a compiler won't catch — auth/permission checks, logging/audit, data-access filters, i18n, safe queries.
4. **Verify each acceptance criterion** is actually implemented, not gestured at.
5. **Watch for model mistakes** — hallucinated imports/paths, half-done edits, dead code, abandoned files, scope creep.
6. **Audit tests** — if the implementer wrote or touched tests, check it didn't game them: hardcoded expected outputs, weakened assertions, skipped/deleted tests.

Produce a **numbered notes list**: each note is a concrete, actionable defect with the file:line and what's wrong. Rank by severity so Cursor fixes the worst first, but **every note must be resolved before approval — minor and polish ones included, not just the critical ones.**

### 4. Run the gates

Run **this project's own** typecheck, lint, and test commands (identified in step 0), on the side(s) the diff touches. Examples of what that looks like across stacks:

```bash
# JS/TS       tsc --noEmit  ·  eslint .  ·  npm test
# Python      mypy .  ·  ruff check .  ·  pytest
# Rust        cargo check  ·  cargo clippy  ·  cargo test
# Go          go vet ./...  ·  go test ./...
```

Use the actual scripts the project defines (e.g. a `package.json` "typecheck"/"lint"/"test" script or a `Makefile` target) rather than guessing flags. Any failure is automatically a note (paste the error).

### 5. Send notes back into the SAME Cursor session

If there are any notes at all, continue Cursor's existing session so it keeps its context:

```bash
cursor-agent -p --force --trust --output-format text --model composer-2.5-fast --resume "<chat-id>" \
  "Review notes to address. Fix each, keep changes uncommitted, don't touch git. \
1. <note> \
2. <note> \
..."
```

Then go back to **step 3**. Repeat the review → gates → notes cycle until:
- all acceptance criteria are met,
- all gates pass,
- **no notes remain at all — every one, however minor.**

Cap at ~5 rounds. If Cursor loops or regresses, STOP and report what's stuck and which files (with the diff summary) — don't burn rounds. The revert rule from step 3 applies: undo only Cursor's mistakes, never the user's work.

## Approval gate (auto-approve criteria)

The user chose **auto-approve on green** — but only with rigorous verification. Auto-approve is permitted **only when ALL of these are simultaneously true**:

- [ ] Every numbered acceptance criterion from the spec is implemented and you verified it in the actual diff (not from Cursor's summary).
- [ ] Every gate passes — the project's typecheck, lint, and tests are all clean on every touched side.
- [ ] **No notes remain at all** — every note from review is fixed, even minimal/polish ones, not just the critical ones; all of the project's mandatory rules and invariants (step 0) hold.
- [ ] The change is complete end-to-end — no TODOs, stubs, dead code, half-wired features, or unhandled edge cases from the spec.
- [ ] Scope matches the spec — nothing unrelated was changed or deleted.

If every box is checked, **approve** and report to the user (see below). Leave changes uncommitted for them to commit.

If any box is **not** checkable with confidence, do NOT auto-approve. Stop, show the user the diff summary, the exact box(es) you couldn't check, and your remaining concern, and ask how to proceed.

## Reporting back

When done (approved or stopped), give the user:
- **What was built** — one paragraph.
- **Acceptance criteria** — the checklist with ✓/✗ each.
- **Rounds** — how many Cursor iterations it took and the gist of what you sent back.
- **Gate results** — typecheck/lint/test status.
- **Files changed** — from `git diff --stat`.
- **Manual follow-ups** — any side-effecting commands the change needs that you deliberately did NOT run (DB migration/push, dependency install, deploy, etc.), spelled out for the user to run themselves. Say "none" if there are none.
- **Verdict** — approved (and "ready to commit"), or stopped-with-concerns.

## Notes

- Assumes `cursor-agent` is installed and logged in — don't pre-check auth; just dispatch. Only if a dispatch returns an auth error, tell the user to run `cursor-agent login` and stop.
- `create-chat` + `--resume <chat-id>` pins every round to this run's own session, so the loop stays cheap (Cursor keeps its context; you send only deltas) and several runs can go in parallel Claude sessions safely. Never use `--continue` or a bare `--resume` — they grab the workspace's most recent session, which may belong to another run.
- If the user's request includes a model override (e.g. "use gpt-5"), honor it via `--model` but keep everything else identical.
- `--mode plan` (read-only) is available if you want Cursor to propose a plan before writing on a risky/large task — optional, use judgment.
