---
name: commit
description: Generate a commit message from staged changes
user-invocable: true
disable-model-invocation: true
---

1. Run `git diff --cached` to see staged changes. If empty, run `git diff` instead.
2. Understand the change before writing: what does it do for the user of the app/tool, and what kind of change is it (feature, fix, refactor, chore, docs...)?
3. Write a commit message to `COMMIT_MESSAGE.md` in the project root. Always in English.

## Format

- First line: conventional commit title (e.g. `feat: add editor change popover`), under ~72 chars.
- Then, only if needed: blank line + bullet points.

## Size the message to the change

- **Small change** (one idea, a tweak, a single fix, a docs line): title only. No bullets.
  e.g. `fix: correct typo in signup error message`
- **Medium change** (a few related things): title + 2-4 bullets.
- **Big change** (many user-facing changes, a release-sized batch): title + one bullet per meaningful change, written like a release changelog.

Never pad. If the title already says it all, stop there.

## Tone of the bullets: match the kind of change

- **User-facing changes** (features, UI, behavior, fixes): write like a release changelog. Describe what changed from the user's point of view, in plain language. Mention the *before -> now* when it helps. Light on file names, function names, and internals.
  - e.g. `- Dashboard charts are larger and easier to read on mobile`
  - e.g. `- Search results now show a preview before opening the item`
  - e.g. `- Fixed settings not saving after switching accounts`
- **Technical changes** (refactor, perf, infra, deps, tests, build, tooling): here the tech *is* the story, so be precise: name the modules, patterns, or mechanisms that changed and why.
  - e.g. `- Extract validation logic into a shared module used by both API routes`
  - e.g. `- Replace polling with a websocket subscription for live updates`
- **Mixed**: user-facing bullets first, then technical ones. Keep the tech bullets brief unless they matter to a reviewer.

Balance: don't hide important technical details (migrations, breaking changes, new env vars, security fixes), but don't drown a user-facing change in implementation noise either.

## Rules

- Each bullet is one line, short and punchy. No paragraphs, no fluff.
- ALWAYS write to the file. NEVER output the message in chat.
- Do NOT run `git commit`. Only write the message file. The user will commit manually.
- If the user passes extra instructions with `/commit`, they override these defaults.
