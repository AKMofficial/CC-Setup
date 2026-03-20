---
name: commit
description: Generate a commit message from staged changes
user-invocable: true
disable-model-invocation: true
---

1. Run `git diff --cached` to see staged changes. If empty, run `git diff` instead.
2. Write a commit message to `COMMIT_MESSAGE.md` in the project root.
3. Format:
   - First line: conventional commit title (e.g. `feat: add editor change popover`)
   - Blank line
   - Bullet points summarizing what changed
4. Keep it concise. No fluff.
5. ALWAYS write to the file. NEVER output the message in chat.
6. Do NOT run `git commit`. Only write the message file. The user will commit manually.
