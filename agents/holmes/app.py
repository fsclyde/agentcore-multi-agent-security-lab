"""HolmesGPT as an A2A worker on AgentCore Runtime.

HolmesGPT does not speak A2A, so this wrapper:
  1. serves A2A on :9000 (the AgentCore contract),
  2. runs a local MCP proxy on 127.0.0.1:8100 that adds HolmesGPT's own
     Cognito token to every call to the AgentCore gateway,
  3. runs `holmes ask` with a config that only has that MCP server:
     no Bash, no built-in Kubernetes access.

Guardrails: the task from the triage agent is checked as input, and the
findings are checked as output before they leave this agent.
"""

import asyncio
import os
import subprocess

import httpx
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import Response

import agent_token
import guard
from a2a import server

GATEWAY_URL = os.environ["GATEWAY_URL"]
CONFIG = "/app/holmes-config.yaml"

# ---------------------------------------------------------------- MCP proxy
proxy = FastAPI()
_http = httpx.AsyncClient(timeout=60)
_PASS_HEADERS = ("content-type", "accept", "mcp-session-id", "mcp-protocol-version")


@proxy.api_route("/mcp", methods=["GET", "POST", "DELETE"])
async def forward(request: Request):
    headers = {k: v for k, v in request.headers.items() if k.lower() in _PASS_HEADERS}
    headers["Authorization"] = f"Bearer {agent_token.get()}"  # HolmesGPT's identity, never the person's
    upstream = await _http.request(request.method, GATEWAY_URL, content=await request.body(), headers=headers)
    out = {k: v for k, v in upstream.headers.items() if k.lower() in _PASS_HEADERS}
    return Response(upstream.content, status_code=upstream.status_code, headers=out)


# ------------------------------------------------------------------- worker
def investigate(task: str) -> str:
    ok, task = guard.check(task, "INPUT")
    if not ok:
        return task

    result = subprocess.run(
        ["holmes", "ask", task, "--config", CONFIG, "--model", f"bedrock/{os.environ['MODEL_ID']}", "--no-interactive"],
        capture_output=True, text=True, timeout=600,
    )
    findings = result.stdout.strip() or f"HolmesGPT failed: {result.stderr.strip()[-500:]}"

    ok, findings = guard.check(findings, "OUTPUT")
    return findings


a2a_app = server(
    name="holmesgpt-investigator",
    description="Investigates Kubernetes incidents with read-only tools. Never changes anything.",
    skills=[{"id": "investigate", "name": "Investigate an incident",
             "description": "Find the likely cause of an incident in the demo namespace and recommend a fix.",
             "tags": ["sre", "kubernetes", "read-only"]}],
    handle=investigate,
)


async def main():
    await asyncio.gather(
        uvicorn.Server(uvicorn.Config(proxy, host="127.0.0.1", port=8100, log_level="warning")).serve(),
        uvicorn.Server(uvicorn.Config(a2a_app, host="0.0.0.0", port=9000)).serve(),
    )


if __name__ == "__main__":
    asyncio.run(main())
