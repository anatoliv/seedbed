+++
seed = "explain-this-code"
model = "qwen3-vl-30b"
seed_hash = "b85c4b8dbf5b"
guide_hash = "00a31dc34d54"
enhancer = "claude-cli"
generated = "2026-09-05"
context = "agent"
+++
You are working in a repository that you can read and run commands in. Your task is to explain what a specific piece of code does. Do not modify any files.

Follow these steps in order.

1. Locate the code. The code to explain is named at the end of this prompt under `Target:`. If it is a file path, read the whole file. If it is a path with a symbol or line range, read the file and then the named region. If a literal snippet is given instead, use the snippet and search the repository for its source file with `grep -rn` so you can read it in context.
2. Read the surrounding context. Identify the callers and the callees. Use `grep -rn "<name>" .` for each function, class, or constant the target defines, and read the definitions of anything it calls that is defined inside this repository.
3. Run one command to confirm your reading of the behaviour. Choose the cheapest one that applies: run the existing tests that cover this code, or run the code on a small input, or start a REPL and call it once. State the exact command you ran and paste its actual output. If nothing can be run, write "Could not run: <reason>" and say so plainly.
4. Write the explanation using the output format below.

Rules.
- Base every claim on text you actually read or output you actually saw. Do not guess at behaviour you did not verify.
- If something in the code is unclear or depends on data you cannot see, say so explicitly under "Unclear" rather than inventing an explanation.
- Do not suggest improvements, refactors, or bug fixes. This task is explanation only.
- Do not change any file. Read-only commands only.

Output format. Use these six headings, in this order, as literal Markdown headings.

## Summary
One or two sentences: what this code does, in plain language.

## Inputs and outputs
A bullet per input (name, type, where it comes from) and per output or return value (type, what it means). Include side effects: files written, network calls, global or shared state mutated, exceptions raised.

## Step by step
A numbered list. One step per meaningful operation in the code, in execution order. Cite the file and line for each step as `path/to/file.py:42`.

## Context
Where this code is called from and what it calls, with `path/to/file.py:line` citations. Two to six bullets.

## Verification
The exact command you ran, in a fenced code block, followed by its real output and one sentence on what the output confirms.

## Unclear
A bullet per thing you could not determine, and why. Write "Nothing unclear." only if that is true.

Worked example of the citation style used in "Step by step":

3. Opens the store file in append mode and writes one JSON line per record — `promptlib/store.py:88`.

Done means: all six headings are present and filled in, every step cites a real file and line number you read, and the Verification section contains a command you actually ran with its real output.

Target:
