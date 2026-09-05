+++
seed = "fix-bug-and-test"
model = "llama-3.3-70b"
seed_hash = "2780e7820e3b"
guide_hash = "2c71265c5f27"
enhancer = "claude-cli"
generated = "2026-09-05"
context = "agent"
+++
You are working in a repository you have full access to: you can read files, run shell commands, and run the test suite. Fix the bug described below. Follow these steps in order. Do not skip a step.

STEP 1 — REPRODUCE THE BUG BEFORE CHANGING ANY CODE.
1a. Read the bug report at the end of this prompt.
1b. Locate the relevant files. Use search commands (`grep -rn "<symbol>" .`, `rg "<symbol>"`, `find . -name "<file>"`) to find the code named in the report.
1c. Run the failing case: run the existing test suite, or the specific test, or the exact command from the report.
1d. Paste the real, unedited failure output (error message, stack trace, or wrong value) into your answer. If you cannot reproduce the failure, STOP and report exactly what you ran and what happened instead. Do not guess at a fix for a bug you have not seen fail.

STEP 2 — FIND THE ROOT CAUSE.
2a. Read the failing function and the code that calls it.
2b. State, in one or two sentences, the exact line or lines that cause the wrong behaviour and why they are wrong. Name the file and line number.
2c. If the true cause is in a different file from where the error appeared, say so.

STEP 3 — WRITE A FAILING TEST FIRST.
3a. Find the existing test file that covers this code. Match its framework, naming, imports and style. Do not introduce a new test framework.
3b. Add a test that reproduces the bug and asserts the correct behaviour.
3c. Run only that test. Confirm it FAILS, and paste the failure output. A test that passes before the fix does not test the bug.

STEP 4 — MAKE THE SMALLEST FIX.
4a. Change only what is needed to correct the root cause from Step 2. Do not reformat unrelated code, rename things, or add features.
4b. Show the diff of your change.

STEP 5 — VERIFY.
5a. Run the new test. Confirm it now PASSES. Paste the output.
5b. Run the whole test suite. Confirm nothing else broke. Paste the summary line (for example `47 passed, 0 failed`).
5c. If any other test now fails, fix it or revert your change and return to Step 2. Do not report success with a red suite.

DONE means all of these are true: the failure was reproduced, a new test failed before the fix and passes after it, and the full suite is green.

OUTPUT FORMAT — use exactly these six headings, in this order:

## 1. Reproduction
<the command you ran and its real output>

## 2. Root cause
<file:line and one or two sentences>

## 3. Failing test
<the test code, and its output showing it fails>

## 4. Fix
<the diff>

## 5. Verification
<new test passing, then full suite summary>

## 6. Summary
<two or three sentences: what was broken, what you changed, what is now covered>

EXAMPLE of the level of detail expected (abbreviated, for shape only):

## 1. Reproduction
`$ pytest tests/test_cart.py::test_total -q`
```
E   assert 0 == 10.0
tests/test_cart.py:14: AssertionError
```

## 2. Root cause
`cart/totals.py:22` — `sum(items)` is called on an empty generator because `items` was already consumed by the `len()` call on line 19, so the total is always 0.

## 3. Failing test
```python
def test_total_with_repeated_iteration():
    cart = Cart([Item(10.0)])
    assert cart.total() == 10.0
```
```
E   assert 0 == 10.0  — FAILED
```

## 4. Fix
```diff
-    items = (i for i in raw)
+    items = [i for i in raw]
```

## 5. Verification
`1 passed` then `47 passed, 0 failed`

## 6. Summary
The cart total was always 0 because the generator was consumed twice. Changed it to a list. A regression test now covers a cart iterated more than once.

RULES:
- Never edit a test to make it pass. Fix the code under test.
- Never delete or skip a test.
- Do not claim a test passes without pasting the output of the run.
- If the fix requires a decision only the user can make (an API change, a behaviour trade-off), stop and ask instead of guessing.

Bug report:
