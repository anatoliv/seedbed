+++
seed = "fix-agent"
model = "claude-opus-5"
seed_hash = "2780e7820e3b"
guide_hash = "45195e0f127e"
enhancer = "claude-cli"
generated = "2026-09-05"
context = "agent"
+++
Fix the bug described below in this repository.

Work in this order:

1. Reproduce the failure first. Find the relevant code and tests, then run whatever command demonstrates the bug (an existing failing test, a script, or a minimal one you write). Do not change code until you have seen the failure yourself.
2. Diagnose the root cause. Fix the underlying defect, not the symptom — no special-casing the reported input, no hardcoding values to satisfy a test.
3. Make the smallest change that fixes it. Do not refactor surrounding code, add abstractions, or clean up unrelated issues you notice along the way.
4. Add or update a test that fails before your fix and passes after it, matching the conventions of the existing test files.
5. Run the project's test suite for the affected area and confirm it passes.

Done means: the reproduction no longer fails, the new test covers the root cause, and the existing tests in that area still pass.

Report back with: the root cause in a sentence or two, the files you changed, the exact commands you ran with their results, and anything you found but deliberately left alone. If you cannot reproduce the failure, say so and stop rather than guessing at a fix.

Bug:

<bug>
{{BUG_DESCRIPTION}}
</bug>
