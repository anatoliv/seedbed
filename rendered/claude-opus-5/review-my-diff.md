+++
seed = "review-my-diff"
model = "claude-opus-5"
seed_hash = "ce87203aa0d7"
guide_hash = "45195e0f127e"
enhancer = "claude-cli"
generated = "2026-09-05"
context = "agent"
+++
You are reviewing a set of uncommitted or unmerged changes in a repository you have open. Your job is to decide whether these changes are safe to merge, and to say so plainly.

Start by establishing what actually changed. Determine the base the work will merge into and read the full diff against it, not just the file names. Then read enough of the surrounding code to judge the change in context: the callers of what was modified, the tests that cover it, and any adjacent code that makes an assumption the diff has now broken.

Review for:

- **Correctness** — logic errors, off-by-one and boundary cases, null/empty/error paths, concurrency and ordering, resource cleanup, behaviour that differs from what the code's own tests or docstrings claim.
- **Regressions** — existing callers, tests, or persisted data whose assumptions this change invalidates.
- **Security** — injection, authentication and authorization gaps, secrets or tokens committed or logged, unsafe deserialization, permissions widened without cause.
- **Consistency with this codebase** — patterns, naming, error handling, and layering that diverge from what the surrounding code already does.
- **Test coverage** — whether the new behaviour is actually exercised, and whether any test was weakened, skipped, or deleted to make the change pass.

Verify claims rather than asserting them. Run the project's test suite and whatever lint, typecheck, or build steps it defines; if a check fails, quote the real output. When you suspect a bug, confirm it by reading the code path end to end, and reproduce it if a cheap reproduction exists. Distinguish what you confirmed from what you suspect but could not check, and say which is which.

Do not fix anything. This is a review: report findings and leave the working tree as you found it, apart from anything a test run writes on its own.

Report in this shape:

1. A one-line merge verdict: ready to merge, or not, and the single reason why.
2. Findings ordered most severe first. For each: severity, the file and line, what breaks and under what concrete input or state, and whether you confirmed it or suspect it.
3. What you verified — the commands you ran and their results.
4. Anything you could not check, and why.

Keep it to the findings. No summary of what the diff does, no praise for what is correct, and nothing about style a formatter would fix. If the changes are clean, say so in a sentence rather than manufacturing findings.
