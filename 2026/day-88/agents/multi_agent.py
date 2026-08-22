"""
Multi-tool DevOps agent - module 3.

Six tools, two domains. The agent picks the domain from the question; I never
tell it whether something is a Docker problem or a Kubernetes one.

  docker : list_containers, get_logs, inspect_container
  k8s    : list_pods, describe_pod, get_events

Run: python3 multi_agent.py
"""

import subprocess

from langchain_core.tools import tool
from langchain_ollama import ChatOllama

try:
    from langchain.agents import create_agent as create_react_agent
except ImportError:  # langchain < 1.0
    from langgraph.prebuilt import create_react_agent

MODEL = "gemma4"

# describe_pod on kube-system dumps a lot of internal detail into the model's
# context for no reason. Read-only, but still worth scoping.
ALLOWED_NAMESPACES = {"default", "devboard", "observability"}


def _run(cmd: list[str], limit: int = 6000) -> str:
    """Run a command, return its output, truncated so it fits the context window."""
    result = subprocess.run(cmd, capture_output=True, text=True)
    out = (result.stdout + result.stderr).strip() or "(no output)"
    if len(out) > limit:
        out = out[:limit] + f"\n\n[...truncated at {limit} chars]"
    return out


def _check_ns(namespace: str) -> str | None:
    if namespace not in ALLOWED_NAMESPACES:
        return (
            f"Refused: namespace '{namespace}' is out of scope "
            f"(allowed: {', '.join(sorted(ALLOWED_NAMESPACES))})."
        )
    return None


# ---------------------------------------------------------------- docker
@tool
def list_containers() -> str:
    """List all Docker containers, running and stopped, with their status."""
    return _run(["docker", "ps", "-a"])


@tool
def get_logs(container_name: str) -> str:
    """Get the last 50 lines of logs from a Docker container by name."""
    return _run(["docker", "logs", "--tail", "50", container_name])


@tool
def inspect_container(container_name: str) -> str:
    """Get detailed config for a Docker container: state, exit code, image, network, mounts."""
    return _run(["docker", "inspect", container_name])


# ------------------------------------------------------------- kubernetes
@tool
def list_pods(namespace: str = "default") -> str:
    """List all Kubernetes pods in a namespace with their status, restarts and age."""
    return _check_ns(namespace) or _run(["kubectl", "get", "pods", "-n", namespace])


@tool
def describe_pod(pod_name: str, namespace: str = "default") -> str:
    """Get full detail for one Kubernetes pod: containers, state, conditions and events."""
    return _check_ns(namespace) or _run(
        ["kubectl", "describe", "pod", pod_name, "-n", namespace]
    )


@tool
def get_events(namespace: str = "default") -> str:
    """Get recent Kubernetes events in a namespace, oldest first. Good for scheduling and image pull problems."""
    return _check_ns(namespace) or _run(
        ["kubectl", "get", "events", "-n", namespace, "--sort-by=.lastTimestamp"]
    )


llm = ChatOllama(model=MODEL, temperature=0)
tools = [
    list_containers, get_logs, inspect_container,
    list_pods, describe_pod, get_events,
]
agent = create_react_agent(llm, tools)

print("\nMulti-Tool DevOps Agent  (docker + kubernetes)")
print("-" * 46)
print("Ask about containers or pods. Type 'quit' to exit.\n")

while True:
    question = input("> ").strip()
    if question.lower() in ("quit", "exit", "q"):
        break
    if not question:
        continue

    print("\nThinking...\n")
    result = agent.invoke({"messages": [("user", question)]})
    print(result["messages"][-1].content)
    print()
