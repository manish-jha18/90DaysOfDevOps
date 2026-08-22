"""
The same Kubernetes agent, but the tools come from the MCP server instead of
being defined in this file. Nothing in here knows what kubectl is.

Run from this folder (the server path below is relative):
    python3 agent_with_mcp.py
"""

import asyncio
import sys

from langchain_mcp_adapters.client import MultiServerMCPClient
from langchain_ollama import ChatOllama

try:
    from langchain.agents import create_agent as create_react_agent
except ImportError:
    from langgraph.prebuilt import create_react_agent

MODEL = "gemma4"


async def main():
    client = MultiServerMCPClient({
        "k8s-tools": {
            "transport": "stdio",
            # sys.executable, not "python" - the venv python is the one with
            # fastmcp installed, and a bare "python" may not be it
            "command": sys.executable,
            "args": ["mcp_server.py"],
        }
    })

    # discovered at runtime, not imported
    tools = await client.get_tools()
    print(f"\nDiscovered {len(tools)} tools from MCP: "
          f"{', '.join(t.name for t in tools)}")

    llm = ChatOllama(model=MODEL, temperature=0)
    agent = create_react_agent(llm, tools)

    print("Ask about your cluster. Type 'quit' to exit.\n")

    history = []
    while True:
        question = input("> ").strip()
        if question.lower() in ("quit", "exit", "q"):
            break
        if not question:
            continue

        history.append({"role": "user", "content": question})
        print("\nThinking...\n")

        try:
            response = await agent.ainvoke({"messages": history})
        except Exception as e:
            print(f"error: {e}\n")
            history.pop()
            continue

        answer = response["messages"][-1]
        print(answer.content)
        print()
        history.append(answer)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nbye")
