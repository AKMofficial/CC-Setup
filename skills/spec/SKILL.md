---
name: spec
description: Turn a vague, one-line feature request into a clear, complete spec. Researches the codebase and the web, asks only the decisions that matter in small batches, then writes the spec to an MD file
argument-hint: "<the rough idea, as vague as it came>"
user-invocable: true
disable-model-invocation: true
---

**Do NOT edit source code. The only file you write is the spec.**

The user gets many short, vague requests from stakeholders. Your job is to do the thinking for them: figure out what the request really means, find everything it touches, decide what you can, ask only what you can't, and hand back a spec that's ready to build.

## 1. Read the request with suspicion

`$ARGUMENTS` is the raw idea. Treat it as a hint, not a spec:
- The wording may be wrong or loose. Figure out the underlying goal (who wants it, what problem it solves) and restate it in clear words.
- A short request often hides a big feature. Expect ripple effects.
- If it's empty, ask for the idea and stop.

## 2. Research before asking anything

Do this before asking anything: don't ask the user what the code or the web can answer.

- **Codebase** (use an Explore agent for broad sweeps): how the related parts work today, and **every place this would touch**. Think beyond the obvious screen: admin/dashboard, API, database and migrations, permissions and roles, settings, notifications, analytics/events, feature flags or experiments, i18n, emails, exports, existing tests, and other features that would behave differently because of this one.
- **Existing patterns:** how similar features were built here, so the spec fits our style, UI, and structure.
- **Web:** how this kind of feature is usually done well, common pitfalls, and the light, efficient, best-practice approach. Note 1-3 useful links.

## 3. Build the decision list

From the research, list every open question. Then sort it:
- **Decide it yourself** if the code, a clear convention, or a sensible default answers it. Record it as an assumption, don't ask.
- **Ask the user** only for real product decisions: behavior, rules, who can do what, what happens in edge cases, what's in or out.
- Order by impact. Questions that depend on another answer wait for the next round.

## 4. Ask in batches

Use the AskUserQuestion tool, **up to 4 questions per round**:
- Plain language, no jargon. Each question says briefly why it matters.
- Put your recommendation first, marked "(Recommended)", with a one-line reason. Use previews for UI or flow choices when it helps.
- The user can always answer "you decide" (take your recommendation) or "ask the stakeholder" (move it to open questions).
- After each round, give a 2-3 line recap of what's now settled, then ask the next batch that the answers unlocked.
- Stop when the remaining unknowns are minor. Usually 1-3 rounds. Don't grill for the sake of it.

## 5. Write the spec

Save to `specs/<feature-slug>.md` (or the project's existing docs/specs folder if it has one). Write it so a teammate or another AI agent can build from it without asking anything:

- **Summary** - what it is and why, in 2-3 lines. The request rewritten the way it should have been written.
- **How it works** - the behavior and user flows, step by step.
- **Decisions** - what was decided and why (from the questions), plus the assumptions you made.
- **Where it touches** - every affected area with file paths, grouped (UI, admin, API, data, etc.).
- **Edge cases** - each one and how it should behave.
- **Approach** - the recommended way to build it: reuse what exists, keep it light and fast, follow best practice. Mention anything to avoid.
- **Out of scope** - what this feature deliberately doesn't do.
- **Open questions** - anything left for the stakeholder, phrased so it can be pasted straight to them.
- **Acceptance criteria** - a checklist of testable items (works as input for `/qa` later).
- **References** - the useful links from the web research.

Keep it tight. No filler, no restating the same thing twice. End by telling the user the file path and any open questions for the stakeholder.
