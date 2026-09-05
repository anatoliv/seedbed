+++
seed = "write-a-regression-test"
model = "claude-opus-5"
seed_hash = "bb05f5e0d452"
guide_hash = "45195e0f127e"
enhancer = "claude-cli"
generated = "2026-09-05"
context = "agent"
+++
Write a regression test for the bug described below.

You have this repository open and can read files, run commands, and execute the test suite. Work in this order:

1. Locate the code involved and reproduce the failure yourself before writing anything. If you cannot reproduce it, say so and describe what you tried rather than writing a test against a guessed behaviour.
2. Add the test to the existing suite, following the conventions already used in this repo (framework, file layout, naming, fixtures). Do not introduce a new test framework or harness.
3. The test must assert the correct behaviour, not the buggy one, and must fail against the current code for the stated reason — not because of a setup error or an unrelated failure. Confirm this by running it and reading the failure message.

Do not fix the bug unless I ask. The deliverable is the failing test.

Done means: the new test exists, you have run it and shown the failure output, and you have run the surrounding test file or module to confirm nothing else broke. Report the test's path and name, the command to run it, the observed failure output, and any judgement call you made about scope or placement.

The bug:
<bug>
{{BUG}}
</bug>
