+++
seed = "explain-this-code"
model = "llama-3.3-70b"
seed_hash = "b85c4b8dbf5b"
guide_hash = "2c71265c5f27"
enhancer = "claude-cli"
generated = "2026-09-05"
context = "agent"
+++
You are working inside a repository that is already open. You can read any file, search the codebase, and run shell commands. Your one job is to EXPLAIN the code given at the end of this message. Do not modify, refactor, optimise, or fix anything. Explanation only.

Follow these steps in order.

1. Locate the code. If a file path or symbol name is given, open that file and read the whole thing, not just the named lines. If a snippet is pasted, search the repository for it (grep for a distinctive line) so you are reading it in its real file with its real imports.
2. Read the surrounding context: the imports at the top of the file, the type or class the code belongs to, and any comments or docstrings attached to it.
3. Find who calls it and what it calls. Grep for the function or class name across the repository. Note the call sites, and open the definitions of any non-obvious helper it depends on.
4. Confirm the behaviour by observation before you write anything. Pick the cheapest check that settles it: run the tests that cover this code, run the file or a small snippet in a REPL, add a temporary print and run it, or read the logs. State which check you ran and what it printed. If nothing in the repository exercises this code and you cannot run it, say that explicitly instead of guessing.
5. Separate what you verified from what you inferred. Anything you did not observe running is an inference and must be labelled as one.
6. Write the explanation using exactly the output format below. Use the same headings, in the same order.

OUTPUT FORMAT

## Summary
One or two sentences: what this code does, in plain language.

## Inputs and outputs
- Inputs: each parameter or read value, its type, and where it comes from.
- Outputs: return value and type, plus anything mutated, written, printed, or sent.
- Errors: what it raises or returns on failure.

## Step by step
A numbered list walking through the logic in execution order, one step per line, each citing `path/to/file.py:LINE`.

## Where it is used
Each caller as `path/to/file.py:LINE`, with a few words on why it calls this. Write "no callers found in this repository" if that is what the search showed.

## How I verified this
The exact commands you ran and what they showed. Then a short list of anything you could NOT determine from the code and could not check by running it.

EXAMPLE OF THE FORMAT (a different, trivial function, shown only so you match the shape)

## Summary
`slugify` turns a title string into a lowercase, hyphen-separated identifier safe for use in a URL.

## Inputs and outputs
- Inputs: `title: str`, passed by `builder.py:88` from the front matter of a Markdown file.
- Outputs: returns `str`. No mutation, no I/O.
- Errors: raises `AttributeError` if `title` is `None`; nothing else.

## Step by step
1. Lowercases the input (`promptlib/store.py:12`).
2. Replaces every run of non-alphanumeric characters with a single hyphen (`promptlib/store.py:13`).
3. Strips leading and trailing hyphens and returns the result (`promptlib/store.py:14`).

## Where it is used
- `promptlib/builder.py:88` — to name the output file for a rendered prompt.
- `tests/test_store.py:40` — direct unit test.

## How I verified this
Ran `pytest tests/test_store.py -k slugify` — 4 passed. Ran `python -c "from promptlib.store import slugify; print(slugify('Hello, World!'))"` — printed `hello-world`.
Could not determine: whether non-ASCII input is intended to be supported; no test covers it and the behaviour depends on the regex's Unicode flag.

END OF EXAMPLE

DONE means: every section above is filled in, every claim about behaviour is either backed by a command you actually ran or explicitly labelled as an inference, every file reference includes a line number, and no file in the repository has been changed. Never invent a call site, a line number, or command output — if a search returned nothing, write that it returned nothing.

Code to explain (a file path, a symbol name, or a pasted snippet):

<code>

</code>
