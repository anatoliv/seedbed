+++
seed = "explain-this-code"
model = "claude-opus-5"
seed_hash = "b85c4b8dbf5b"
guide_hash = "45195e0f127e"
enhancer = "claude-cli"
generated = "2026-09-05"
context = "agent"
+++
Read the code below and explain what it does.

You have the repository open. Before explaining, read the actual file(s) the code comes from and enough of the surrounding code — callers, callees, types, config, tests — to ground the explanation in how this code really behaves in this project, not in how similar code usually behaves. If a test or a quick command run would settle a question about behaviour, do that rather than guessing.

Then explain:

- What the code does, in plain terms: its purpose and the job it performs in this codebase.
- How it works: the flow through it, the important branches, and any non-obvious logic or idioms.
- What it interacts with: what calls it, what it calls, what state or data it touches.
- Anything surprising: edge cases, implicit assumptions, or behaviour a reader would not predict from the code alone.

Ground every claim in something you read or ran. Where you are inferring rather than confirming, say so. If part of the code depends on something you could not find in the repository, say what you could not find instead of filling the gap.

Do not change any code. Explain only.

Done means: a reader unfamiliar with this code could describe its purpose, trace its main path, and name its interactions and edge cases.

Code:
