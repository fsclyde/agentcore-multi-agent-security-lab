"""AgentCore Gateway interceptor (REQUEST and RESPONSE).

REQUEST, before the Cedar policy engine:
  1. Only tools/call is checked; tools/list, initialize and the rest pass.
  2. The person's Cognito access token must be in X-On-Behalf-Of. Cognito
     itself checks it (GetUser): signature, expiry and sign-out. It must come
     from the people's CLI client.
  3. The operator only acts for an sre-admin, and the write tool is refused
     unless the person is in sre-admin.
  4. For the write tool only, _agent, _on_behalf_of and _on_behalf_of_role
     are written into the arguments, overwriting anything the agent sent.
     Cedar reads them as context.input.*, and the write Lambda uses them for
     Kubernetes impersonation. Calls to the upstream Kubernetes MCP server
     are left unchanged, because its tool schemas do not have these fields;
     the person is still checked here, and logged with every call.

RESPONSE, before the agent sees the result:
  5. The text of every tool result goes through the Bedrock guardrail, as
     untrusted input: prompt attacks and AWS keys are blocked, tokens,
     passwords and e-mails are masked.
"""

import base64
import json
import os

import boto3

cognito = boto3.client("cognito-idp")
bedrock = boto3.client("bedrock-runtime")

USER_CLIENT_ID = os.environ["USER_CLIENT_ID"]
WRITE_TARGET = os.environ["WRITE_TARGET"]
GUARDRAIL = {"guardrailIdentifier": os.environ["GUARDRAIL_ID"], "guardrailVersion": os.environ["GUARDRAIL_VERSION"]}
KNOWN_AGENTS = {"holmes", "operator"}


def _out(request_body=None, response=None):
    mcp = {}
    if request_body is not None:
        mcp["transformedGatewayRequest"] = {"body": request_body}
    if response is not None:
        mcp["transformedGatewayResponse"] = response
    return {"interceptorOutputVersion": "1.0", "mcp": mcp}


def _deny(body, reason):
    print(json.dumps({"decision": "DENY", "reason": reason, "tool": body.get("params", {}).get("name")}))
    return _out(response={"statusCode": 403, "body": {
        "jsonrpc": "2.0", "id": body.get("id", 1), "error": {"code": -32000, "message": f"Denied by the gateway: {reason}"}}})


def _claims(token):
    try:
        payload = token.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except (IndexError, ValueError):
        return {}


def _person(token):
    """Returns (username, role) or raises ValueError."""
    if not token:
        raise ValueError("no X-On-Behalf-Of token")
    token = token.removeprefix("Bearer ").strip()
    try:
        user = cognito.get_user(AccessToken=token)  # Cognito validates the token, including sign-out
    except cognito.exceptions.NotAuthorizedException as err:
        raise ValueError("the person's token is not valid") from err
    claims = _claims(token)
    if claims.get("client_id") != USER_CLIENT_ID or claims.get("token_use") != "access":
        raise ValueError("the person's token was not issued to the people's client")
    groups = claims.get("cognito:groups", [])
    role = "sre-admin" if "sre-admin" in groups else "sre-viewer" if "sre-viewer" in groups else "none"
    return user["Username"], role


def on_request(mcp):
    body = mcp["gatewayRequest"]["body"]
    if body.get("method") != "tools/call":
        return _out(request_body=body)

    headers = {k.lower(): v for k, v in mcp["gatewayRequest"].get("headers", {}).items()}
    try:
        username, role = _person(headers.get("x-on-behalf-of"))
    except ValueError as err:
        return _deny(body, str(err))

    agent = headers.get("x-agent-name", "")
    if agent not in KNOWN_AGENTS:
        return _deny(body, "unknown agent")  # Cedar also binds this name to the agent's IAM role
    if role == "none":
        return _deny(body, f"{username} is not in an SRE group")

    tool = body["params"]["name"]
    is_write = tool.startswith(f"{WRITE_TARGET}___")
    if (is_write or agent == "operator") and role != "sre-admin":
        return _deny(body, f"{username} ({role}) cannot ask for a change")

    if is_write:
        args = dict(body["params"].get("arguments") or {})
        args.update(_agent=agent, _on_behalf_of=username, _on_behalf_of_role=role)
        body["params"]["arguments"] = args
    print(json.dumps({"decision": "PASS", "tool": tool, "agent": agent, "on_behalf_of": username, "role": role}))
    return _out(request_body=body)


def on_response(mcp):
    response = mcp["gatewayResponse"]
    request = mcp["gatewayRequest"]["body"]
    body = response.get("body") or {}
    result = body.get("result") if isinstance(body, dict) else None
    if request.get("method") != "tools/call" or not isinstance(result, dict) or not result.get("content"):
        return _out(response={"statusCode": response.get("statusCode", 200), "body": body})

    text = "\n".join(c.get("text", "") for c in result["content"] if c.get("type") == "text")
    verdict = bedrock.apply_guardrail(**GUARDRAIL, source="INPUT", content=[{"text": {"text": text}}])

    if verdict["action"] == "GUARDRAIL_INTERVENED":
        blocked = "BLOCKED" in json.dumps(verdict.get("assessments", []))
        masked = "".join(o.get("text", "") for o in verdict.get("outputs", []))
        print(json.dumps({"guardrail": "INTERVENED", "blocked": blocked, "tool": request["params"]["name"]}))
        body["result"] = {
            "isError": blocked,
            "content": [{"type": "text", "text": "Blocked by the gateway guardrail: the tool result contained "
                                                   "content that cannot be passed to an agent." if blocked else masked}],
        }

    return _out(response={"statusCode": response.get("statusCode", 200), "body": body})


def handler(event, context):
    mcp = event["mcp"]
    return on_response(mcp) if "gatewayResponse" in mcp else on_request(mcp)
