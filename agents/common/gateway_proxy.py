"""Local MCP proxy to the AgentCore gateway, inside the agent's container.

The agent framework (HolmesGPT, Strands) talks plain MCP to
http://127.0.0.1:8100/mcp. For every request the proxy:
  - signs it with SigV4 using the agent's own IAM role (the runtime role):
    that is how the gateway knows which agent is calling, with no secret;
  - attaches the person's token in X-On-Behalf-Of: that is how the gateway
    knows who the agent is acting for;
  - names the agent in X-Agent-Name (signed). Cedar checks that this name
    matches the signed role.

The person's token is the one the current A2A request arrived with. A worker
handles one request at a time, so it is kept for the duration of that request.
"""

import os
import threading

import httpx
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.session import Session
from fastapi import FastAPI, Request
from fastapi.responses import Response

GATEWAY_URL = os.environ["GATEWAY_URL"]
REGION = os.environ["AWS_REGION"]
AGENT = os.environ["AGENT_NAME"]
_PASS = ("content-type", "accept", "mcp-session-id", "mcp-protocol-version")

_credentials = Session().get_credentials()
_lock = threading.Lock()
_current = {"bearer": ""}


class acting_for:
    """with acting_for(bearer): ... -> tool calls in this block carry this person."""

    def __init__(self, bearer: str):
        self.bearer = bearer

    def __enter__(self):
        _lock.acquire()
        _current["bearer"] = self.bearer
        return self

    def __exit__(self, *exc):
        _current["bearer"] = ""
        _lock.release()


app = FastAPI()
_http = httpx.AsyncClient(timeout=60)


@app.api_route("/mcp", methods=["GET", "POST", "DELETE"])
async def forward(request: Request):
    body = await request.body()
    headers = {k: v for k, v in request.headers.items() if k.lower() in _PASS}
    headers["X-Agent-Name"] = AGENT
    headers["X-On-Behalf-Of"] = _current["bearer"]

    signed = AWSRequest(method=request.method, url=GATEWAY_URL, data=body, headers=headers)
    SigV4Auth(_credentials.get_frozen_credentials(), "bedrock-agentcore", REGION).add_auth(signed)

    upstream = await _http.request(request.method, GATEWAY_URL, content=body, headers=dict(signed.headers))
    out = {k: v for k, v in upstream.headers.items() if k.lower() in _PASS}
    return Response(upstream.content, status_code=upstream.status_code, headers=out)
