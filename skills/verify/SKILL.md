---
name: verify
description: Verify unstaged changes are safe code cleanup with zero functional or visual difference
user-invocable: true
disable-model-invocation: true
---

**READ-ONLY. Do NOT edit, write, or modify any file. Only read and report.**

1. Run `git diff` to see all unstaged changes.
2. For each changed file, verify:
   - **Same final result**: `1+1` → `2` is FINE. Only flag changes where the output/behavior actually differs.
   - **Same UI/design**: Layout, ordering, spacing, colors, animations, hover effects, transitions - identical to the user.
   - **Same buttons and interactions**: Click handlers, navigation, modals, popovers - all work exactly the same.
   - **No missing features**: Nothing removed, no conditions dropped, no edge cases lost.
3. Only flag a change if it **genuinely changes what the user sees or experiences**.
4. Judge the quality of each change:
   - Does it actually improve readability, performance, or maintainability?
   - Or is it just unnecessary churn that doesn't add value?
5. Report:
   - **Safe and worth staging**: Changes that are clean, correct, and improve the code.
   - **Safe but not worth it**: Changes that don't break anything but add no real value - recommend discarding.
   - **Unsafe**: Changes that alter behavior/UI - explain exactly what changed.
6. End with a clear verdict: stage all, stage some (which ones), or discard.
7. Keep it short. No fluff.
