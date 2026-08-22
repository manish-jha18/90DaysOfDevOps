# Day 88 – Multi-Tool Agents, MCP, and the CI/CD Analyzer

Code in `agents/`, manifest in `k8s/`, Claude Desktop config in `mcp/`. Reference repo modules 3 and 6.

---

## Task 1: One agent, two domains

Yesterday's agent had three Docker tools. Today it has six across Docker and Kubernetes, and **I never tell it which domain a question belongs to.**

Something broken on each side:

```
devops@testvm:~$ kind create cluster --name devops-demo
Creating cluster "devops-demo" ...
 ✓ Ensuring node image (kindest/node:v1.30.0)
 ✓ Starting control-plane 🕹️
Set kubectl context to "kind-devops-demo"

devops@testvm:~/day-88$ kubectl apply -f k8s/broken-pod.yaml
pod/broken-pod created

devops@testvm:~$ docker run -d --name broken-container nginx:alpine \
    sh -c "echo 'container starting...' && sleep 2 && exit 1"
7c1e4b902fa8

devops@testvm:~$ kubectl get pods
NAME         READY   STATUS             RESTARTS      AGE
broken-pod   0/1     CrashLoopBackOff   4 (31s ago)   2m18s
```

**The six tools, same pattern as yesterday:**

| Tool | Command |
|---|---|
| `list_containers` | `docker ps -a` |
| `get_logs` | `docker logs --tail 50` |
| `inspect_container` | `docker inspect` |
| `list_pods` | `kubectl get pods -n <ns>` |
| `describe_pod` | `kubectl describe pod` |
| `get_events` | `kubectl get events --sort-by=.lastTimestamp` |

**The cross-domain question:**

```
(.venv) devops@testvm:~/day-88/agents$ python3 multi_agent.py

Multi-Tool DevOps Agent  (docker + kubernetes)
----------------------------------------------
Ask about containers or pods. Type 'quit' to exit.

> What's broken across Docker and Kubernetes?

Thinking...

Two things, and they are the same failure in two places.

Docker:
  broken-container - Restarting (1). Its command is
  `sh -c "echo 'container starting...' && sleep 2 && exit 1"`, so it exits
  with code 1 two seconds after every start.

Kubernetes:
  broken-pod - CrashLoopBackOff, 4 restarts. Same shape: the container prints
  "app starting...", sleeps 2s, exits 1. The events show BackOff with
  "Back-off restarting failed container app".

Neither is an image, network or resource problem. Both containers pulled
nginx:alpine fine. In both cases the command itself is what fails, so the
restart loop will never resolve on its own.
```

**Four tool calls: two Docker, two Kubernetes.** I asked one question in English and it worked out that "across Docker and Kubernetes" means using both sets.

```
> Why is broken-pod crashing?

Thinking...

broken-pod is in CrashLoopBackOff after 4 restarts.

The pod spec overrides the image command with:
    sh -c "echo 'app starting...' && sleep 2 && exit 1"

kubectl describe shows Last State: Terminated, Reason: Error, Exit Code: 1,
and the events end with "Back-off restarting failed container app in pod
broken-pod_default". The back-off is now 40s and doubles each time.

nginx:alpine is not the problem - it pulled successfully. Removing the
`command` override so nginx runs its own entrypoint would fix it.

> Are there any unhealthy containers on Docker?
```

That last one used only `list_containers`. **The number of tool calls scales with the question**, which is the whole point of the loop.

### One thing I added

`describe_pod` on `kube-system` dumps a lot of internal detail into the model's context for nothing, so all three Kubernetes tools check a namespace list first:

```python
ALLOWED_NAMESPACES = {"default", "devboard", "observability"}
```

```
> describe the coredns pod in kube-system

Thinking...

I can't - the tool refused: namespace 'kube-system' is out of scope
(allowed: default, devboard, observability).
```

Read-only tools, so this is scope hygiene rather than safety. It also keeps the context focused, which measurably improved the answers.

---

## Task 2: What MCP actually is

**MCP is a protocol for exposing tools to AI clients.** Instead of writing tool functions inside one agent, you run a small server that publishes them, and any MCP-speaking client discovers and calls them.

The problem it fixes is duplication. My `list_pods` currently exists in `multi_agent.py`. If I want the same thing in Claude Desktop, in VS Code, and in a colleague's agent, that is four copies drifting apart.

| Without MCP | With MCP |
|---|---|
| Tools live inside LangChain code | Tools are a service any client can call |
| Every client reimplements `list_pods` | Written once, discovered at runtime |
| Adding a tool means editing the agent | Adding a tool means restarting the server |

```
                     +---------------------------+
                     |   mcp_server.py           |
                     |   "Kubernetes Tools"      |
                     |                           |
                     |   list_pods()             |
                     |   describe_pod()          |
                     |   get_events()            |
                     +-------------+-------------+
                                   |
                        stdio  (or HTTP)
                                   |
        +--------------+-----------+-----------+--------------+
        |              |                       |              |
   Claude Desktop   VS Code               Claude Code    agent_with_mcp.py
                    Copilot                (this CLI)     (LangChain)
```

**stdio vs HTTP.** stdio means the client launches the server as a child process and talks over stdin/stdout — simplest for anything local. HTTP is for a server running elsewhere, which is also where you start needing authentication, because an HTTP endpoint that runs `kubectl` is a remote code execution service if it is open.

---

## Task 3: Building the MCP server

**`agents/mcp_server.py`** — the same three functions, one decorator different:

```python
from fastmcp import FastMCP

mcp = FastMCP("Kubernetes Tools")

@mcp.tool
def list_pods(namespace: str = "default") -> str:
    """List all Kubernetes pods in a namespace with their status, restarts and age."""
    ...

if __name__ == "__main__":
    mcp.run()
```

**`@mcp.tool` instead of `@tool`, and `mcp.run()` at the bottom.** The function bodies are identical. The docstrings still matter for the same reason — they travel over the protocol as the tool descriptions.

### The stdio trap

stdio means **the protocol is stdout**. A stray `print()` in the server corrupts the JSON-RPC stream and the client fails to connect with something unhelpful. I found this by adding a debug print and spending ten minutes on it. Logging has to go to stderr or a file, never stdout, and the file carries a comment saying so.

**The client, `agents/agent_with_mcp.py`:**

```python
client = MultiServerMCPClient({
    "k8s-tools": {
        "transport": "stdio",
        "command": sys.executable,
        "args": ["mcp_server.py"],
    }
})

tools = await client.get_tools()   # discovered, not imported
agent = create_react_agent(llm, tools)
```

**`sys.executable`, not `"python"`.** The reference version uses the string `"python"`, which resolves through PATH and on my box is not the venv interpreter — so the subprocess started without `fastmcp` installed and died immediately. `sys.executable` is the interpreter currently running, which is by definition the one that has the dependencies.

```
(.venv) devops@testvm:~/day-88/agents$ python3 agent_with_mcp.py

Discovered 3 tools from MCP: list_pods, describe_pod, get_events
Ask about your cluster. Type 'quit' to exit.

> Why is broken-pod crashing?

Thinking...

CrashLoopBackOff, 6 restarts. The container command exits with code 1 two
seconds after starting, so kubelet restarts it and the back-off keeps
doubling - currently 80s. Exit Code: 1, Reason: Error in the last state.
```

**Same answer, and nothing in the agent file knows what `kubectl` is.** It asked the server what it could do and got three tools back.

Two things I changed from the reference:

- Its server key is `"docker-mcp"` while the server serves Kubernetes tools. Renamed to `k8s-tools`.
- It runs at `temperature=0.8`. The reference README says use 0 for troubleshooting agents, and it is right — 0.8 gave me a different diagnosis wording each run and once an invented pod name. Mine is 0.

### Claude Desktop

`mcp/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "kubernetes-tools": {
      "command": "/home/devops/agentic-ai-for-devops/.venv/bin/python3",
      "args": ["/home/devops/day-88/agents/mcp_server.py"]
    }
  }
}
```

Absolute paths for both, and specifically **the venv's python3** — same reason as `sys.executable`. Claude Desktop launches this with its own environment, not my shell's, so nothing is on PATH and no venv is active.

After a restart, asking Claude Desktop "list the pods in my cluster" makes it call `list_pods` on my machine and come back with `broken-pod  0/1  CrashLoopBackOff`. **My laptop's kubectl, driven by an app I did not write.** That is the part that made MCP click for me — the tools are no longer part of any one program.

---

## Task 4: The CI/CD Failure Analyzer

Same pattern, `gh` instead of `kubectl`. Three tools: list runs, fetch failed logs, read the workflow file.

A deliberate failure to analyse, in a scratch repo:

```yaml
name: Broken CI
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm test
```

```
devops@testvm:~/ci-test$ git push
devops@testvm:~/ci-test$ gh run list --status failure --limit 3
STATUS  TITLE            WORKFLOW    BRANCH  EVENT  ID           AGE
X       add broken ci    Broken CI   main    push   17284391045  1m
```

```
(.venv) devops@testvm:~/ci-test$ python3 ~/day-88/agents/ci_analyzer.py

CI/CD Failure Analyzer
----------------------------------------
> What failed in my last CI run?

Thinking...

Run 17284391045 ("Broken CI") failed at the "Run npm test" step.

The log ends with:

    npm error code ENOENT
    npm error syscall open
    npm error path /home/runner/work/ci-test/ci-test/package.json
    npm error errno -2
    npm error enoent Could not read package.json

There is no package.json in the repo, so npm has nothing to run. The
checkout succeeded - the repo just is not a Node project.

Looking at broken-ci.yml, the job goes straight from actions/checkout@v4 to
`npm test` with no setup-node step and no `npm ci`. Even with a package.json
present it would fail, because dependencies are never installed.
```

**It fetched the logs and read the workflow file without being asked to do either.** The second half — "even with a package.json it would still fail, because there is no `npm ci`" — is the bit I liked. That is not in the error message; it came from cross-referencing two tools.

### Truncation, and the one change I made

`get_failed_logs` truncates, because a failed Docker build easily prints 200 KB and Gemma 4's context is nowhere near that.

The reference keeps the **first** 5000 characters. I keep the **last**:

```python
if len(out) > limit:
    # keep the TAIL, not the head - the error is at the end of a build log
    out = f"[...truncated, showing last {limit} chars]\n\n" + out[-limit:]
```

Tested against a real failed devboard run. Head-truncated, the model got 5000 characters of `npm ci` progress bars and answered "the build appears to be installing dependencies; I cannot determine the failure". Tail-truncated, it got the actual error and diagnosed it. **The error is at the end of a build log, always.**

---

## Task 5: The tool I built

Not one of the three suggested. Days 84–86 left me with a real gap: **CI succeeding does not mean the change is running.** CI ends at a git commit now; ArgoCD does the rest. So the question "did my change deploy?" spans both, and nothing answers it in one place.

```python
@tool
def argocd_app_status(app_name: str) -> str:
    """Get the sync status, health and deployed git revision of an ArgoCD application. Use this to check whether a successful CI run actually reached the cluster."""
    return _run(
        ["argocd", "app", "get", app_name, "--output", "wide", "--refresh"],
        limit=3000,
    )
```

```
(.venv) devops@testvm:~/devboard$ python3 ~/day-88/agents/ci_analyzer.py

> My last CI run passed. Is the change actually running in the cluster?

Thinking...

No, not yet.

CI: run 17284402118 on main succeeded 4 minutes ago, and its update-manifest
job committed c4d2e58 ("chore: deploy sha-a91f3c4 [skip ci]").

ArgoCD: the devboard application reports

    Sync Status:   OutOfSync from mega-project (c4d2e58)
    Health Status: Progressing
    Revision:      8a3f91c

ArgoCD has seen the new commit but is still on the previous revision
(8a3f91c) and the sync is in progress. The image tag in the cluster is
therefore still sha-8a3f91c. Give it another minute and re-check - if it is
still Progressing after that, look at the rollout.
```

**That answer needed both halves of the pipeline** and neither tool alone could have produced it. It also picked `argocd_app_status` off the phrase "running in the cluster", which is only in the docstring — the tool name never mentions clusters.

Two notes on building it: the docstring says *why* to use the tool, not what command it runs, which is what got the selection right. And `--refresh` is in there deliberately, so the answer reflects the repo now rather than ArgoCD's last poll.

---

## The template

Every tool in this block is the same eight lines:

```python
@tool
def my_tool(argument: str) -> str:
    """What this tells you, and when you would want it."""
    result = subprocess.run(
        ["some-cli", "subcommand", argument],
        capture_output=True, text=True,
    )
    out = (result.stdout + result.stderr).strip() or "(no output)"
    return out[-5000:] if len(out) > 5000 else out
```

Four rules that came out of today:

1. **Return a string.** The model cannot read objects, JSON structures or binary.
2. **Include stderr.** Failures are the interesting output, and CLIs put them there.
3. **Truncate, from the tail.** Every real command can exceed the context window.
4. **Write the docstring for the model.** Say what it tells you and when you would want it, not which command it runs.

---

## Cleanup

```
devops@testvm:~$ kind delete cluster --name devops-demo
Deleting cluster "devops-demo" ...
devops@testvm:~$ docker rm -f broken-container
broken-container
devops@testvm:~$ deactivate
```

---

## Files in this folder

| Path | What it is |
|---|---|
| `agents/multi_agent.py` | 6 tools, Docker + Kubernetes, namespace scoped |
| `agents/mcp_server.py` | The Kubernetes tools as an MCP server |
| `agents/agent_with_mcp.py` | The same agent with tools discovered over MCP |
| `agents/ci_analyzer.py` | `gh` tools + my `argocd_app_status` tool |
| `k8s/broken-pod.yaml` | Something for the agent to diagnose |
| `mcp/claude_desktop_config.json` | Wiring the server into Claude Desktop |

---

## What I learned

**1. Under stdio, stdout is the protocol.** One debug `print()` in the MCP server corrupts the JSON-RPC stream, and the client reports a connection failure that says nothing about why. All logging goes to stderr or a file. This is the MCP-specific gotcha nothing warned me about.

**2. Truncate CI logs from the tail, not the head.** The reference keeps the first 5000 characters, which on a real run is 5000 characters of `npm ci` progress bars — the model answered "cannot determine the failure". Keeping the last 5000 gave it the actual error. Errors are at the end of a build log, always.

**3. MCP turns tools from code into a service.** The same three functions, one decorator different, are now callable by Claude Desktop, VS Code and my own agent — none of which contain the word `kubectl`. Adding a tool is a server restart, not an edit to four programs.

**Two extras:**

- `sys.executable`, not `"python"`, when a client spawns the server. A bare `"python"` resolves through PATH and is usually not the venv interpreter, so the subprocess starts without its dependencies and dies with a traceback the client swallows.
- The docstring is what drives tool selection, so write it in terms of the question it answers. `argocd_app_status` got picked from the phrase "running in the cluster", which appears only in its docstring and nowhere in the function name.
