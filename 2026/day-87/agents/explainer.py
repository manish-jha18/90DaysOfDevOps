"""
Docker Error Explainer - paste a docker error, get a plain-English fix.

Module 1 of the reference repo, with one change: the system prompt asks for
the exact command, not a description of the command. Without that line the
model kept answering "remove the existing container and try again", which is
true and useless.

Run: python3 explainer.py
"""

import ollama

MODEL = "gemma4"

SYSTEM_PROMPT = """You are a Docker expert. When given a Docker error, explain:
1. What went wrong (plain English)
2. Most likely cause
3. How to fix it

For step 3 give the exact command to run, not a description of it.
Keep the whole answer under 10 lines."""

print("\nPaste your Docker error (press Enter twice when done):\n")

lines = []
while True:
    line = input()
    if line == "":
        break
    lines.append(line)
error = "\n".join(lines)

if not error.strip():
    raise SystemExit("nothing pasted")

print("\nThinking...\n")

response = ollama.chat(
    model=MODEL,
    messages=[
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": error},
    ],
    # low temperature - for a technical answer I want the same output every
    # time, not a creative one
    options={"temperature": 0.3},
)

print(response["message"]["content"])
