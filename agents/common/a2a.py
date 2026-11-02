"""A deliberately small A2A layer, so every security decision stays visible.

server(): a FastAPI app that follows the AgentCore A2A contract
  POST /                              JSON-RPC 2.0, method message/send
  GET  /.well-known/agent-card.json   Agent Card
  GET  /ping                          health check

call(): send message/send to another agent hosted on AgentCore Runtime,
  forwarding the person's bearer token.
"""

import json
import os
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Callable

from fastapi import FastAPI, Request

REGION = os.environ.get("AWS_REGION", "eu-west-1")


def server(name: str, description: str, skills: list[dict], handle: Callable[[str], str]) -> FastAPI:
    app = FastAPI()

    @app.get("/ping")
    def ping():
        return {"status": "Healthy"}

    @app.get("/.well-known/agent-card.json")
    def card():
        return {
            "name": name,
            "description": description,
            "version": "1.0.0",
            "url": os.environ.get("AGENTCORE_RUNTIME_URL", "http://localhost:9000/"),
            "protocolVersion": "0.3.0",
            "preferredTransport": "JSONRPC",
            "capabilities": {"streaming": False},
            "defaultInputModes": ["text"],
            "defaultOutputModes": ["text"],
            "skills": skills,
        }

    @app.post("/")
    async def rpc(request: Request):
        req = await request.json()
        rid = req.get("id")
        if req.get("method") != "message/send":
            return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "Method not found"}}
        parts = req["params"]["message"].get("parts", [])
        text = "\n".join(p.get("text", "") for p in parts if p.get("kind") == "text")
        answer = handle(text)
        return {
            "jsonrpc": "2.0",
            "id": rid,
            "result": {
                "kind": "message",
                "role": "agent",
                "messageId": str(uuid.uuid4()),
                "parts": [{"kind": "text", "text": answer}],
            },
        }

    return app


def runtime_url(agent_arn: str) -> str:
    escaped = urllib.parse.quote(agent_arn, safe="")
    return f"https://bedrock-agentcore.{REGION}.amazonaws.com/runtimes/{escaped}/invocations/"


def call(agent_arn: str, text: str, bearer: str, session_id: str) -> tuple[int, str]:
    """Returns (http_status, text). A 401/403 means AgentCore refused the person's token for that agent."""
    payload = {
        "jsonrpc": "2.0",
        "id": str(uuid.uuid4()),
        "method": "message/send",
        "params": {"message": {"role": "user", "messageId": str(uuid.uuid4()),
                               "parts": [{"kind": "text", "text": text}]}},
    }
    req = urllib.request.Request(
        runtime_url(agent_arn),
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": bearer,
            "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id": session_id,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            status, body = resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as err:
        raw = err.read().decode()
        try:
            body = json.loads(raw)
        except ValueError:
            return err.code, raw[:300]
        status = err.code

    if "error" in body:
        return status, f"error {body['error'].get('code')}: {body['error'].get('message')}"
    parts = body.get("result", {}).get("parts", [])
    return status, "\n".join(p.get("text", "") for p in parts)
