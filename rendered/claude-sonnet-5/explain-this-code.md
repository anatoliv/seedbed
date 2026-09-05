+++
seed = "explain-this-code"
model = "claude-sonnet-5"
seed_hash = "b85c4b8dbf5b"
guide_hash = "c3fe8e403112"
enhancer = "claude-cli"
generated = "2026-09-05"
context = "agent"
+++
You are working in a repository you can read and run commands in. Your task is to explain what a piece of code does. Explain only — do not modify any files.

The code is given at the end of this message. It may be a snippet, a whole file, or a path.

Steps:

1. Locate the code in the repository. Use search to find the file it comes from, and read enough of the surrounding file to see its imports, its types, and the functions it sits next to. If the supplied text does not exist in the repo, say so and explain it as standalone text.
2. Trace the edges. Find who calls it and what it calls. Read the definitions of any non-obvious helper, type, or constant it depends on, rather than inferring behaviour from the name.
3. Check the code's own evidence. Read any tests that exercise it, and any docstrings or comments. If a cheap, read-only command settles a question about behaviour (running an existing test, `git log -p` on the file, a one-line REPL check), run it instead of guessing.

Then write the explanation with these sections:

- **Purpose** — one or two sentences: what this code is for, in the context of the surrounding system, not a restatement of the syntax.
- **How it works** — a walkthrough of the actual control and data flow. Say what goes in, what comes out, and what changes along the way (mutated state, I/O, side effects, exceptions raised).
- **Where it fits** — callers, callees, and the invariants the callers rely on. Cite specific locations as `path/to/file.py:LINE`.
- **Non-obvious details** — edge cases, error handling, concurrency or ordering assumptions, performance characteristics, or anything that would surprise a reader who only skimmed it. Include anything the surrounding code or tests revealed that the snippet alone does not show.
- **Uncertain** — anything you could not determine, and what would settle it. Omit this section only if there is nothing in it.

Rules for the explanation:

- Every claim about behaviour must be grounded in code you actually read in this repository. If you are inferring rather than confirming, mark the sentence with "likely" and say what you did not check.
- Do not describe bugs as intended behaviour, and do not propose fixes or refactors — this is an explanation, not a review. If you notice something that looks wrong, note it in one line under **Non-obvious details** and move on.
- Skip the line-by-line paraphrase of self-evident statements. Spend the words on why, not on what a reader can see.
- Name real identifiers and real file paths throughout. No placeholders.

You are done when every section above is written, every file path and line reference you cite resolves to something you actually opened, and nothing in the repository that the code obviously depends on is left unread.

<code>
{{CODE}}
</code>
