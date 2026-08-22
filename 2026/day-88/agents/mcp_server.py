"""
MCP server exposing Kubernetes tools.

Same three functions as the k8s half of multi_agent.py, but registered with
FastMCP instead of LangChain. Any MCP client can now use them - Claude Desktop,
VS Code, Claude Code, or agent_with_mcp.py in this folder.

Run directly:  python3 mcp_server.py     (stdio transport)
Or let the client start it - that is the normal case.
"""

import subprocess

from fastmcp import FastMCP

mcp = FastMCP("Kubernetes Tools")

ALLOWED_NAMESPACES = {"default", "devboard", "observability"}


def _run(cmd: list[str], limit: int = 6000) -> str:
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


@mcp.tool
def list_pods(namespace: str = "default") -> str:
    """List all Kubernetes pods in a namespace with their status, restarts and age."""
    return _check_ns(namespace) or _run(["kubectl", "get", "pods", "-n", namespace])


@mcp.tool
def describe_pod(pod_name: str, namespace: str = "default") -> str:
    """Get full detail for one Kubernetes pod: containers, state, conditions and events."""
    return _check_ns(namespace) or _run(
        ["kubectl", "describe", "pod", pod_name, "-n", namespace]
    )


@mcp.tool
def get_events(namespace: str = "default") -> str:
    """Get recent Kubernetes events in a namespace, oldest first. Good for scheduling and image pull problems."""
    return _check_ns(namespace) or _run(
        ["kubectl", "get", "events", "-n", namespace, "--sort-by=.lastTimestamp"]
    )


if __name__ == "__main__":
    # stdio by default. The client launches this as a subprocess and talks to
    # it over stdin/stdout, so nothing else may print to stdout - a stray
    # print() here corrupts the protocol.
    mcp.run()
