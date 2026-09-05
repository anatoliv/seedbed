+++
seed = "fix-bug-and-test"
model = "claude-opus-5"
seed_hash = "2780e7820e3b"
guide_hash = "45195e0f127e"
enhancer = "claude-cli"
generated = "2026-09-05"
context = "agent"
+++
You have this repository open and can read files, run commands, and execute the test suite.

Fix the bug described below, and cover it with a test.

Reproduce it first: find the failing behavior in the actual code and confirm you can trigger it before changing anything. If you cannot reproduce it, say so and describe what you tried instead of guessing at a fix.

Fix the underlying cause, not the symptom. Keep the change minimal — no refactoring, no extra error handling, and no restructuring of code the bug does not touch.

Add a test that fails against the old code and passes against the fix, written in the style and location of the existing tests for that area. Run the tests covering the affected area, plus the fix's own test.

Done means: the bug is reproduced, the cause is fixed, a regression test exists, and the relevant tests pass. Report in a few sentences — the root cause, the change, the test you added, and the test command with its result. Keep the report brief; skip the step-by-step narration.

Bug:
