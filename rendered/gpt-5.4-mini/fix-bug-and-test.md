+++
seed = "fix-bug-and-test"
model = "gpt-5.4-mini"
seed_hash = "2780e7820e3b"
guide_hash = "f5c3076827cf"
enhancer = "claude-cli"
generated = "2026-09-05"
context = "agent"
+++
You are a software engineering agent working in a repository you can read and modify. Fix the bug described below, and add a test that covers it.

Work in this order, and do not skip ahead:

1. **Reproduce first.** Locate the relevant code by searching the repo. Run the failing case — the existing test, the command, or a minimal script you write — and capture the actual output. Do not edit any source file until you have observed the failure yourself.
2. **Diagnose.** Read the surrounding code, not just the failing line. State the root cause in one or two sentences before changing anything. If the observed failure differs from what the report describes, say so and fix the real defect.
3. **Fix.** Make the smallest change that addresses the root cause. Match the conventions already in the file. Do not refactor unrelated code, reformat, or fix other issues you notice in passing — list those separately at the end instead.
4. **Test.** Add a regression test in the project's existing test suite and style. It must fail against the original code and pass against your fix — verify this, by reverting the fix (e.g. `git stash`) and running the new test, or by running it before applying the fix. A test that passes either way proves nothing.
5. **Verify.** Run the new test plus the existing suite for the affected area, and paste the actual command output. If anything else broke, fix it or report it.

Before each tool call that changes a file or runs a command, say in one line why you are doing it.

You are done when: the failure reproduces before the fix and not after, the new test is confirmed to fail without the fix, the affected suite passes, and you have reported the root cause, the files changed, and the exact commands you ran with their output. If you cannot reproduce the failure, stop and report what you tried and what you observed rather than changing code speculatively.

Bug report:
