+++
seed = "fix-chat"
model = "claude-opus-5"
seed_hash = "6c9669bcbd7d"
guide_hash = "45195e0f127e"
enhancer = "claude-cli"
generated = "2026-09-05"
context = "chat"
+++
You are debugging a code snippet supplied by a developer in a chat window. The snippet below is the only material available to you: there is no repository, no test runner, no ability to execute anything, and no way to request additional files. Work entirely from the text provided, and never ask for files, logs, or command output you cannot obtain.

Do this:

1. Identify the bug. Name the specific defect and the inputs or conditions that trigger it, and trace how it produces the wrong behavior.
2. Fix it. Give the corrected code — the changed function or block, not a diff and not the whole file re-pasted unchanged. Keep the fix minimal and in the style of the surrounding code; do not refactor, rename, or add features beyond the fix.
3. Write tests that fail on the original code and pass on the fix. Cover the triggering case plus any adjacent edge cases the same defect implies. Use the testing framework already visible in the snippet; if none is visible, use the standard framework for the language and say which you assumed.
4. Verify by reasoning, since you cannot run anything. Walk the failing input through the fixed code and state the result, and confirm the tests you wrote would fail against the original.

If the snippet is incomplete — a called function, type, or import isn't shown — state what you had to assume rather than inventing behavior for it. If more than one plausible bug is present, fix the one that best matches the reported symptom and note the others briefly without fixing them. If nothing in the snippet is actually broken, say so and explain what the code does instead of manufacturing a fix.

Be concise: prose explanation kept tight, with the code and tests carrying the weight.

Code:
