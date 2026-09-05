+++
seed = "fix-bug-and-test"
model = "qwen3-vl-30b"
seed_hash = "2780e7820e3b"
guide_hash = "00a31dc34d54"
enhancer = "claude-cli"
generated = "2026-09-05"
context = "agent"
+++
You are fixing a bug in a repository you have open. Work through the numbered steps in order. Do not skip a step.

1. Read the bug report at the end of this prompt. Restate the bug in one sentence: what happens now, and what should happen instead. If the report does not say what the expected behaviour is, write down the expected behaviour you inferred and say that you inferred it.

2. Locate the code. Search the repository for the file, function, error message, or symbol named in the bug report. List every file path you opened and why. Do not guess at file contents — read the files.

3. Reproduce the bug BEFORE changing any code. Run the failing command, test, or script and paste the exact output you got. If you cannot reproduce it, stop and report what you ran, what happened instead, and what you would need in order to reproduce it. Do not proceed to step 4 without a reproduction.

4. Find the root cause. State the specific line or lines that cause the wrong behaviour, and explain in two or three sentences why that code produces the observed output. Do not describe the symptom again — name the defect.

5. Write a failing test first. Add a test that fails because of this bug, in the repository's existing test framework and in the directory where its tests already live. Run it. Paste the output showing it fails, and showing the failure is the bug from step 3 and not a broken test.

6. Fix the bug. Change only the code needed to fix this defect. Do not reformat unrelated lines, rename unrelated things, or add features the bug report does not ask for.

7. Verify. Run these in order and paste the output of each:
   a. The test you added in step 5 — it must now pass.
   b. The repository's full test suite — report the pass and fail counts. If any test fails, say whether it was failing before your change.
   c. The original reproduction from step 3 — it must now show correct behaviour.

8. Report using exactly this format:

```
BUG: <one sentence>
ROOT CAUSE: <file>:<line> — <one sentence>
FIX: <what you changed, one or two sentences>
TEST ADDED: <path to test file>::<test name>
VERIFICATION:
  new test: PASS | FAIL
  full suite: <N> passed, <M> failed
  reproduction: FIXED | NOT FIXED
FILES CHANGED:
  - <path>
  - <path>
```

Rules:
- Read files and run commands to establish facts. Do not assume how the code behaves.
- If step 3 or step 7 fails, report the failure honestly with its output. Do not claim a fix that you did not verify.
- Done means: the new test passes, the full suite has no new failures, and the reproduction shows correct behaviour.

Bug report:
