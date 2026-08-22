"""
Docker Troubleshooter Agent - module 2, plus the two tools task 6 asks for.

Five tools:
  read-only : list_containers, get_logs, inspect_container, list_images
  writes    : restart_container  <- guarded, see below

Run: python3 docker_agent.py
"""

import subprocess

from langchain_core.tools import tool
from langchain_ollama import ChatOllama

# langchain 1.x renamed create_react_agent to create_agent and moved it into
# langchain.agents. The old langgraph.prebuilt import still works on 0.3.x, so
# try the new name first and fall back.
try:
    from langchain.agents import create_agent as create_react_agent
except ImportError:  # langchain < 1.0
    from langgraph.prebuilt import create_react_agent

MODEL = "gemma4"

# restart_container can change the state of the machine, so it only works on
# containers I have listed here. An agent with an unrestricted restart tool
# will eventually restart something I did not mean it to.
RESTARTABLE = {"broken-app", "devboard-backend", "devboard-frontend"}


def _run(cmd: list[str]) -> str:
    """Run a command and return whatever it printed, stdout or stderr."""
    result = subprocess.run(cmd, capture_output=True, text=True)
    out = result.stdout + result.stderr
    return out.strip() or "(no output)"


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


@tool
def list_images() -> str:
    """List all Docker images on this machine with their tags and sizes on disk."""
    return _run(["docker", "images"])


@tool
def restart_container(container_name: str) -> str:
    """Restart a Docker container by name. Only works on containers that are on the allowed list."""
    if container_name not in RESTARTABLE:
        return (
            f"Refused: '{container_name}' is not on the allowed list "
            f"({', '.join(sorted(RESTARTABLE))}). A human has to do this one."
        )
    return _run(["docker", "restart", container_name])


llm = ChatOllama(model=MODEL, temperature=0)
tools = [list_containers, get_logs, inspect_container, list_images, restart_container]
agent = create_react_agent(llm, tools)

print("\nDocker Troubleshooter Agent")
print("-" * 30)
print("Ask me about your Docker containers. Type 'quit' to exit.\n")

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
