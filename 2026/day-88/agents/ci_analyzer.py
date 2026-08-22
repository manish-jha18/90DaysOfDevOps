"""
CI/CD Failure Analyzer - module 6, plus one tool of my own.

Tools:
  list_workflow_runs   gh run list
  get_failed_logs      gh run view --log-failed   (truncated)
  get_workflow_file    reads .github/workflows/<name>
  argocd_app_status    argocd app get             <- mine, see below

Run from inside a repo with GitHub Actions. Needs `gh auth login`.
    python3 ci_analyzer.py
"""

import pathlib
import subprocess

from langchain_core.tools import tool
from langchain_ollama import ChatOllama

try:
    from langchain.agents import create_agent as create_react_agent
except ImportError:
    from langgraph.prebuilt import create_react_agent

MODEL = "gemma4"

# CI logs are the one place where truncation is not optional. A failed docker
# build can print 200 KB; gemma4's context is nowhere near that.
LOG_LIMIT = 5000


def _run(cmd: list[str], limit: int = LOG_LIMIT) -> str:
    result = subprocess.run(cmd, capture_output=True, text=True)
    out = (result.stdout + result.stderr).strip() or "(no output)"
    if len(out) > limit:
        # keep the TAIL, not the head - the error is at the end of a build log
        out = f"[...truncated, showing last {limit} chars]\n\n" + out[-limit:]
    return out


@tool
def list_workflow_runs(status: str = "failure") -> str:
    """List recent GitHub Actions workflow runs. Use status='failure' for failed runs, 'success' for passing ones."""
    return _run(["gh", "run", "list", "--status", status, "--limit", "5"], limit=2000)


@tool
def get_failed_logs(run_id: str) -> str:
    """Get the logs of the failed steps in one GitHub Actions run. Pass the numeric run ID from list_workflow_runs."""
    return _run(["gh", "run", "view", run_id, "--log-failed"])


@tool
def get_workflow_file(workflow_name: str) -> str:
    """Read a GitHub Actions workflow YAML file from this repo. Pass just the filename, like 'ci.yml'."""
    path = pathlib.Path(".github/workflows") / workflow_name
    if not path.exists():
        available = sorted(p.name for p in pathlib.Path(".github/workflows").glob("*.y*ml"))
        return f"No such file: {path}. Available: {', '.join(available) or 'none'}"
    return path.read_text()[:LOG_LIMIT]


@tool
def argocd_app_status(app_name: str) -> str:
    """Get the sync status, health and deployed git revision of an ArgoCD application. Use this to check whether a successful CI run actually reached the cluster."""
    return _run(
        ["argocd", "app", "get", app_name, "--output", "wide", "--refresh"],
        limit=3000,
    )


llm = ChatOllama(model=MODEL, temperature=0)
tools = [list_workflow_runs, get_failed_logs, get_workflow_file, argocd_app_status]
agent = create_react_agent(llm, tools)

print("\nCI/CD Failure Analyzer")
print("-" * 40)
print("Run me from inside a repo with GitHub Actions.")
print("Type 'quit' to exit.\n")

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
