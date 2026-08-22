# Day 87 – Introduction to Agentic AI for DevOps

Code in `agents/` in this folder. Reference repo: `TrainWithShubham/agentic-ai-for-devops`, modules 0–2.

---

## Task 1: What an agent actually is

**A chatbot generates text. An agent runs commands.** That is the whole difference.

Every day so far has been me typing a command, reading the output, deciding what to type next. An agent is an LLM doing that loop, with the commands wrapped as Python functions it is allowed to call.

**Why DevOps fits this well:** everything is a CLI. `docker`, `kubectl`, `terraform`, `gh`, `ansible` — all of them take text arguments and print text. That is exactly the shape an LLM can work with. There is no API to design; `subprocess.run(["docker", "ps", "-a"])` is already a tool.

### The ReAct loop

Reason, Act, Observe — repeated until the model has an answer.

```
me:    "Why is broken-app crashing?"

THINK  I don't know what containers exist. Check first.
ACT    list_containers()
OBS    broken-app   Restarting (1) 4 seconds ago

THINK  It's restarting, so it exits and gets restarted. Logs will say why.
ACT    get_logs("broken-app")
OBS    app starting...
       app starting...
       app starting...

THINK  It prints that and dies. I need the exit code.
ACT    inspect_container("broken-app")
OBS    "ExitCode": 1,  "Restarting": true

ANSWER The container's command runs `echo && sleep 2 && exit 1`. It exits
       with code 1 every time and the restart policy brings it back.
```

**I never told it to read the logs.** I asked one question and it picked three tools in a sensible order. That is the part that is genuinely different from a script.

**Four components:**

| Part | What it is | Here |
|---|---|---|
| LLM | the brain | Gemma 4 via Ollama, local |
| Tools | the hands | Python functions wrapping `docker` |
| Framework | the loop | LangChain `create_agent` |
| MCP | tool sharing | Day 88 |

---

## Task 2: Environment setup

**Ollama first** — local model, no API key, no cost, and nothing leaves the machine. That last part matters: a `kubectl describe` dumps env var names, image registries and internal hostnames, and I would rather not post that to a hosted API while learning.

```
devops@testvm:~$ curl -fsSL https://ollama.com/install.sh | sh
>>> Installing ollama to /usr/local
>>> Creating ollama systemd service...
>>> The Ollama API is now available at 127.0.0.1:11434.

devops@testvm:~$ systemctl is-active ollama
active

devops@testvm:~$ ollama pull gemma4
pulling manifest
pulling 3f8eb4da87fa: 100% ▕████████████████▏ 4.8 GB
verifying sha256 digest
success

devops@testvm:~$ ollama list
NAME             ID              SIZE      MODIFIED
gemma4:latest    3f8eb4da87fa    4.8 GB    2 minutes ago
```

The installer set it up as a systemd unit — which is Day 04, and it means I do not need `ollama serve &` in a terminal.

**Python environment:**

```
devops@testvm:~$ git clone https://github.com/TrainWithShubham/agentic-ai-for-devops.git
devops@testvm:~$ cd agentic-ai-for-devops
devops@testvm:~/agentic-ai-for-devops$ python3 -m venv .venv
devops@testvm:~/agentic-ai-for-devops$ source .venv/bin/activate
(.venv) devops@testvm:~/agentic-ai-for-devops$ pip install -r requirements.txt
Successfully installed langchain-1.0.3 langchain-core-0.3.29 langchain-mcp-adapters-0.1.9
langchain-ollama-0.3.10 langgraph-0.6.7 fastmcp-2.11.3 ollama-0.5.1
```

Six packages: `ollama` (the client), `langchain` + `langchain-ollama` (the agent framework), `langgraph` (the graph the ReAct loop runs on), `fastmcp` and `langchain-mcp-adapters` (Day 88).

**Pre-flight check:**

```
(.venv) devops@testvm:~/agentic-ai-for-devops$ python3 module-0/verify_setup.py

Checking your setup...

  [PASS] Python 3.10+
  [PASS] Docker
  [PASS] kubectl
  [FAIL] Kind — install kind
  [PASS] Ollama + gemma4

————————————————————————————————————————
  4/5 passed — fix the failures above
```

Kind was the one gap — I have been using EKS and minikube, never Kind.

```
devops@testvm:~$ go install sigs.k8s.io/kind@v0.23.0
devops@testvm:~$ kind version
kind v0.23.0 go1.22.3 linux/amd64
```

```
  5/5 — you're ready for Day 1!
```

---

## Task 3: The Docker Error Explainer

**`agents/explainer.py`** — no agent, no tools, one LLM call. This is the baseline to compare the agent against.

```python
response = ollama.chat(
    model="gemma4",
    messages=[
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": error},
    ],
    options={"temperature": 0.3},
)
```

```
(.venv) devops@testvm:~/day-87/agents$ python3 explainer.py

Paste your Docker error (press Enter twice when done):

Error response from daemon: driver failed programming external connectivity on
endpoint myapp: Bind for 0.0.0.0:8080 failed: port is already allocated.

Thinking...

1. What went wrong
   Docker could not publish port 8080 on the host. Something else is already
   listening on it.

2. Most likely cause
   An older container from a previous `docker run` is still running and holds
   8080, or a process on the host (a dev server) has the port.

3. How to fix it
   docker ps --filter "publish=8080"
   docker rm -f <container-id>
   # if it's a host process instead:
   sudo ss -ltnp | grep :8080
```

Correct, and faster than the two searches I would otherwise have done.

### What the system prompt does

I changed it to find out. **The system prompt is where all the control is** when there is no agent loop.

| System prompt | What came back |
|---|---|
| *(none)* | Four paragraphs about Docker networking. Accurate, no fix. |
| `"You are a Docker expert."` | Right topic, but rambled and gave three alternatives without picking one. |
| The 3-point version | Structured, short, actionable. |
| 3-point + `"give the exact command, not a description"` | The `docker ps --filter` line above, instead of "find and remove the old container". |

**That last line is the one that made it useful.** Without it I got advice; with it I got something I could paste. My version in `agents/explainer.py` keeps it.

**Temperature 0.3** — low means near-deterministic. Same error in, same explanation out. At 0.9 I got a different phrasing every run and once a fix for the wrong error. For technical answers, low temperature every time.

---

## Task 4: The Docker Troubleshooter Agent

Something to diagnose first:

```
devops@testvm:~$ docker run -d --name broken-app nginx:alpine \
    sh -c "echo 'app starting...' && sleep 2 && exit 1"
a3f91c2e8b4d

devops@testvm:~$ docker ps -a
CONTAINER ID   IMAGE          COMMAND                  STATUS                          NAMES
a3f91c2e8b4d   nginx:alpine   "sh -c 'echo app st…"   Restarting (1) 3 seconds ago    broken-app
```

The Docker equivalent of CrashLoopBackOff.

**The tool pattern**, which does not change for the rest of the block:

```python
@tool
def get_logs(container_name: str) -> str:
    """Get the last 50 lines of logs from a Docker container by name."""
    result = subprocess.run(
        ["docker", "logs", "--tail", "50", container_name],
        capture_output=True, text=True,
    )
    return result.stdout + result.stderr
```

**The docstring is not a comment.** It is sent to the model as the tool's description and is the only thing it has to decide whether this tool is the right one. `"""Get the last 50 lines of logs from a Docker container by name."""` works; `"""runs docker logs"""` does not, because the model has to already know what `docker logs` does to pick it.

**Running it:**

```
(.venv) devops@testvm:~/day-87/agents$ python3 docker_agent.py

Docker Troubleshooter Agent
------------------------------
Ask me about your Docker containers. Type 'quit' to exit.

> Why is broken-app crashing?

Thinking...

broken-app crashes because its command is designed to fail. The container
runs:

    sh -c "echo 'app starting...' && sleep 2 && exit 1"

It prints "app starting...", waits 2 seconds, then exits with code 1. Docker
inspect confirms "ExitCode": 1 and "Restarting": true, and the logs show the
same line repeated once per restart cycle.

The container itself is healthy - nginx:alpine pulled fine and there is no
image or network problem. The command is the whole issue.

Fix: give it a command that stays running.
    docker rm -f broken-app
    docker run -d --name broken-app nginx:alpine
```

**Three tool calls, none of which I asked for.** It listed containers, read logs, then inspected. That order is what I would have done.

Some more, to see the tool selection:

```
> Is any container using port 8080?

Thinking...

No. Checking docker ps -a, the only container is broken-app, which publishes
no ports at all (its PORTS column is empty). Port 8080 is free as far as
Docker is concerned - if something is holding it, it is a host process.

> What image is broken-app using?

Thinking...

nginx:alpine.
```

**The second one used one tool, not three.** It did not read logs to answer a question about the image. That is the ReAct loop working — the number of steps matches the difficulty of the question.

---

## Task 5: The architecture

```
                        [ my question ]
                               |
                               v
                 +-------------------------+
                 |   Gemma 4 via Ollama    |   the brain
                 |   (runs on this laptop) |
                 +-----------+-------------+
                             |
             REASON: which tool, with what arguments?
                             |
                             v
                 +-------------------------+
                 |     tool selection      |
                 +-----------+-------------+
                             |
      +----------------+-----+------+----------------+
      |                |            |                |
      v                v            v                v
list_containers    get_logs   inspect_container   list_images
      |                |            |                |
 docker ps -a    docker logs   docker inspect   docker images
      |                |            |                |
      +----------------+-----+------+----------------+
                             |
                    OBSERVE: text output
                             |
                             v
                 +-------------------------+
                 |  LLM reads and reasons  |
                 |  again -- loop until    |
                 |  the answer is ready    |
                 +-----------+-------------+
                             |
                             v
                     [ final answer ]
```

**The loop is the only interesting part, and I did not write it.** `create_agent(llm, tools)` builds it. My code is five functions and three lines of setup.

**Nothing here is Docker-specific except the four `subprocess.run` calls.** Swap them for `kubectl` and the same file is a Kubernetes agent — which is literally Day 88.

---

## Task 6: The tools I added

**`list_images`** — straightforward:

```
> What images do I have and how much space are they using?

Thinking...

Four images, 1.42 GB total:

  nginx:alpine                  52.5 MB
  manishjha18/devboard-backend  sha-a91f3c4    284 MB
  manishjha18/devboard-frontend sha-a91f3c4    71.3 MB
  postgres:16-alpine            1.01 GB

postgres:16-alpine is nearly three quarters of it.
```

It picked the new tool on the first try, because "images" and "space" are both in the docstring.

**`restart_container` — and this is where I stopped and thought.**

The reference version restarts anything by name. Mine does not:

```python
RESTARTABLE = {"broken-app", "devboard-backend", "devboard-frontend"}

@tool
def restart_container(container_name: str) -> str:
    """Restart a Docker container by name. Only works on containers that are on the allowed list."""
    if container_name not in RESTARTABLE:
        return (
            f"Refused: '{container_name}' is not on the allowed list "
            f"({', '.join(sorted(RESTARTABLE))}). A human has to do this one."
        )
    return _run(["docker", "restart", container_name])
```

```
> broken-app keeps crashing, can you restart it?

Thinking...

Restarted broken-app. It came back up and immediately began restarting again -
the container is now "Restarting (1) 2 seconds ago", same as before.

Restarting does not help here. The command exits with code 1 by design, so it
will fail identically every time. This needs a different command, not a
restart.

> restart the postgres container too

Thinking...

I can't. restart_container refused: 'postgres' is not on the allowed list
(broken-app, devboard-backend, devboard-frontend). That one needs a human.
```

**Two things worth keeping from that.**

First, the agent restarted it, watched it fail again, and said restarting was the wrong fix. It did not report success just because the tool returned without error.

Second, **the guardrail is in the tool, not in the prompt.** I could have written "do not restart the database" in a system prompt and the model would usually obey. A list check in Python obeys every time. The same reasoning as Day 49 — a policy that depends on cooperation is not a control.

**The thing I keep coming back to:** the tool functions here are five lines each and completely dumb. There is no logic in them. All the intelligence is in the model deciding when to call them, and all the safety is in what I refuse to let them do.

---

## Files in this folder

| Path | What it is |
|---|---|
| `agents/explainer.py` | Single LLM call, no tools. Sharpened system prompt. |
| `agents/docker_agent.py` | 5-tool ReAct agent, with an allowlist on the one tool that writes |

---

## What I learned

**1. The docstring is the tool's interface, not documentation.** It is the only thing the model sees when choosing a tool. `"""Get the last 50 lines of logs from a Docker container by name."""` gets picked correctly; `"""runs docker logs"""` does not, because it assumes the model already knows what that command does. A wrong tool choice is almost always a bad docstring rather than a bad model.

**2. Guardrails belong in the tool, not in the prompt.** Writing "don't restart production" in a system prompt is a request the model usually honours. An allowlist check in Python is a control that always holds. Anything the agent can do, it will eventually do — so the limits have to be in code, the same argument as Day 49's least-privilege `permissions:`.

**3. One line in the system prompt was the difference between advice and a fix.** Adding "give the exact command, not a description of it" turned "remove the old container" into `docker ps --filter "publish=8080"`. With no agent loop, the system prompt is the entire product.

**Two extras:**

- `temperature=0.3` or lower for anything technical. At 0.9 the same error produced a different answer each run, and once a fix for a different problem entirely.
- The reference repo imports `from langchain.agents import create_agent as create_react_agent`, which only exists in langchain 1.x. On 0.3.x it is `from langgraph.prebuilt import create_react_agent`. My `docker_agent.py` tries the new name and falls back, because the README and the code disagree about which one it is.
