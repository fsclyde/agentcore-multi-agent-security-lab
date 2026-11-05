"""HolmesGPT as an A2A worker on AgentCore Runtime.

HolmesGPT does not speak A2A, so this wrapper:
  1. serves A2A on :9000 (the AgentCore contract),
  2. runs a local MCP proxy on 127.0.0.1:8100 (common/gateway_proxy.py) that
     signs every gateway call with HolmesGPT's own IAM role and attaches the
     person's token, so the gateway sees both,
  3. runs `holmes ask` with a config that only has that MCP server:
     no Bash, no built-in Kubernetes access.

Guardrails: the task from the triage agent is checked as input, and the
findings are checked as output before they leave this agent.
"""

import asyncio
import os
import subprocess

import uvicorn

import gateway_proxy
import guard
from a2a import server

CONFIG = "/app/holmes-config.yaml"

# ------------------------------------------------------------------- worker
def investigate(task: str, bearer: str) -> str:
    ok, task = guard.check(task, "INPUT")
    if not ok:
        return task

    with gateway_proxy.acting_for(bearer):
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
        uvicorn.Server(uvicorn.Config(gateway_proxy.app, host="127.0.0.1", port=8100, log_level="warning")).serve(),
        uvicorn.Server(uvicorn.Config(a2a_app, host="0.0.0.0", port=9000)).serve(),
    )


if __name__ == "__main__":
    asyncio.run(main())
