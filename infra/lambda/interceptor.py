"""AgentCore Gateway interceptor (REQUEST and RESPONSE).

REQUEST, before the Cedar policy engine:
  1. Only tools/call is checked; tools/list, initialize and the rest pass.
  2. The person's Cognito access token must be in X-On-Behalf-Of. It is
     validated here, without a network call per request: RS256 signature
     against the pool's cached signing keys, issuer, expiry, token use and
     the people's client. Tokens live 5 minutes.
  3. The operator only acts for an sre-admin, and the write tool is refused
     unless the person is in sre-admin.
  4. The write tool also needs:
       - a live session: Cognito GetUser, so a signed-out person is refused
         at once even with an unexpired token;
       - an approved change (four eyes): an approval record for this exact
         change, by another sre-admin, not expired and not used before.
         The record is deleted when it is used.
  5. For the write tool only, _agent, _on_behalf_of and _on_behalf_of_role
     are written into the arguments, overwriting anything the agent sent.
     Cedar reads them as context.input.*, and the write Lambda uses them for
     Kubernetes impersonation. Calls to the Kubernetes MCP server are left
     unchanged; the person is still checked here and logged with every call.

RESPONSE, before the agent sees the result:
  6. The text of every tool result goes through the Bedrock guardrail, as
     untrusted input: prompt attacks and AWS keys are blocked, tokens,
     passwords and e-mails are masked.

Every decision is one JSON log line; CloudWatch metric filters count denials,
guardrail interventions and writes (infra/interceptor.tf).
"""

import base64
import hashlib
import hmac
import json
import os
import time
import urllib.request

import boto3

REGION = os.environ["AWS_REGION"]
USER_POOL_ID = os.environ["USER_POOL_ID"]
USER_CLIENT_ID = os.environ["USER_CLIENT_ID"]
WRITE_TARGET = os.environ["WRITE_TARGET"]
APPROVAL_PREFIX = os.environ["APPROVAL_PREFIX"]  # e.g. /acsl/approvals/
GUARDRAIL = {"guardrailIdentifier": os.environ["GUARDRAIL_ID"], "guardrailVersion": os.environ["GUARDRAIL_VERSION"]}
KNOWN_AGENTS = {"holmes", "operator"}
ISSUER = f"https://cognito-idp.{REGION}.amazonaws.com/{USER_POOL_ID}"

cognito = boto3.client("cognito-idp")
bedrock = boto3.client("bedrock-runtime")
ssm = boto3.client("ssm")

_jwks = {"keys": {}, "fetched": 0.0}
_SHA256_DIGEST_INFO = bytes.fromhex("3031300d060960864801650304020105000420")


# ------------------------------------------------------------------ tokens
def _b64(data: str) -> bytes:
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))


def _signing_key(kid: str):
    if kid not in _jwks["keys"] and time.time() - _jwks["fetched"] > 60:
        with urllib.request.urlopen(f"{ISSUER}/.well-known/jwks.json", timeout=5) as resp:
            keys = json.loads(resp.read())["keys"]
        _jwks.update(keys={k["kid"]: k for k in keys}, fetched=time.time())
    return _jwks["keys"].get(kid)


def _verify(token: str, leeway: int = 0) -> dict:
    """RS256 verification with the standard library only (PKCS#1 v1.5, SHA-256)."""
    try:
        header_b64, payload_b64, sig_b64 = token.split(".")
        header, claims = json.loads(_b64(header_b64)), json.loads(_b64(payload_b64))
    except ValueError as err:
        raise ValueError("malformed token") from err
    if header.get("alg") != "RS256":
        raise ValueError("unexpected token algorithm")

    key = _signing_key(header.get("kid", ""))
    if not key:
        raise ValueError("unknown signing key")
    n = int.from_bytes(_b64(key["n"]), "big")
    e = int.from_bytes(_b64(key["e"]), "big")
    size = (n.bit_length() + 7) // 8
    signed = pow(int.from_bytes(_b64(sig_b64), "big"), e, n).to_bytes(size, "big")
    digest = _SHA256_DIGEST_INFO + hashlib.sha256(f"{header_b64}.{payload_b64}".encode()).digest()
    expected = b"\x00\x01" + b"\xff" * (size - len(digest) - 3) + b"\x00" + digest
    if not hmac.compare_digest(signed, expected):
        raise ValueError("bad token signature")

    if claims.get("iss") != ISSUER or claims.get("token_use") != "access":
        raise ValueError("token not issued by the lab's user pool")
    if claims.get("client_id") != USER_CLIENT_ID:
        raise ValueError("token not issued to the people's client")
    if claims.get("exp", 0) + leeway < time.time():
        raise ValueError("token expired")
    return claims


def _role(claims: dict) -> str:
    groups = claims.get("cognito:groups", [])
    return "sre-admin" if "sre-admin" in groups else "sre-viewer" if "sre-viewer" in groups else "none"


def _person(header_value):
    """Returns (username, role, token) or raises ValueError."""
    if not header_value:
        raise ValueError("no X-On-Behalf-Of token")
    token = header_value.removeprefix("Bearer ").strip()
    claims = _verify(token)
    return claims["username"], _role(claims), token


# ------------------------------------------------------------------ approvals
def _check_approval(args: dict, requester: str):
    """Four eyes: another sre-admin approved exactly this change. Single use."""
    change_id = str(args.get("change_id", ""))
    if not change_id.replace("-", "").isalnum():
        raise ValueError("a change_id is required for a change")
    name = f"{APPROVAL_PREFIX}{change_id}"
    try:
        record = json.loads(ssm.get_parameter(Name=name, WithDecryption=True)["Parameter"]["Value"])
    except ssm.exceptions.ParameterNotFound as err:
        raise ValueError(f"change {change_id} is not approved") from err

    approver = _verify(record["approver_token"], leeway=600)  # signed by Cognito when it was approved
    if _role(approver) != "sre-admin":
        raise ValueError("the approver is not an sre-admin")
    if approver["username"] == requester:
        raise ValueError("a change cannot be approved by the person who asks for it")
    if not (approver["iat"] - 60 <= record["approved_at"] <= approver["exp"] + 60):
        raise ValueError("the approval was not made with the approver's session")
    if record["requested_by"] != requester or record["expires"] < time.time():
        raise ValueError(f"change {change_id} is for someone else or has expired")
    for field in ("namespace", "name", "container", "image"):
        if record.get(field) != args.get(field):
            raise ValueError(f"the request does not match the approved {field}")

    ssm.delete_parameter(Name=name)  # single use
    return change_id, approver["username"]


# ------------------------------------------------------------------ gateway
def _out(request_body=None, response=None):
    mcp = {}
    if request_body is not None:
        mcp["transformedGatewayRequest"] = {"body": request_body}
    if response is not None:
        mcp["transformedGatewayResponse"] = response
    return {"interceptorOutputVersion": "1.0", "mcp": mcp}


def _deny(body, reason, **log):
    print(json.dumps({"decision": "DENY", "reason": reason, "tool": body.get("params", {}).get("name"), **log}))
    return _out(response={"statusCode": 403, "body": {
        "jsonrpc": "2.0", "id": body.get("id", 1), "error": {"code": -32000, "message": f"Denied by the gateway: {reason}"}}})


def on_request(mcp):
    body = mcp["gatewayRequest"]["body"]
    if body.get("method") != "tools/call":
        return _out(request_body=body)

    headers = {k.lower(): v for k, v in mcp["gatewayRequest"].get("headers", {}).items()}
    try:
        username, role, token = _person(headers.get("x-on-behalf-of"))
    except ValueError as err:
        return _deny(body, str(err))

    agent = headers.get("x-agent-name", "")
    log = {"agent": agent, "on_behalf_of": username, "role": role}
    if agent not in KNOWN_AGENTS:
        return _deny(body, "unknown agent", **log)  # Cedar also binds the name to the signed IAM role
    if role == "none":
        return _deny(body, f"{username} is not in an SRE group", **log)

    tool = body["params"]["name"]
    is_write = tool.startswith(f"{WRITE_TARGET}___")
    if (is_write or agent == "operator") and role != "sre-admin":
        return _deny(body, f"{username} ({role}) cannot ask for a change", **log)

    if is_write:
        args = dict(body["params"].get("arguments") or {})
        try:
            cognito.get_user(AccessToken=token)  # session still live (global sign-out takes effect at once)
        except cognito.exceptions.NotAuthorizedException:
            return _deny(body, f"{username}'s session was revoked", **log)
        try:
            change_id, approver = _check_approval(args, username)
        except (ValueError, KeyError) as err:
            return _deny(body, str(err), **log)
        args.update(_agent=agent, _on_behalf_of=username, _on_behalf_of_role=role)
        body["params"]["arguments"] = args
        log.update(change_id=change_id, approved_by=approver)

    print(json.dumps({"decision": "PASS", "tool": tool, "write": is_write, **log}))
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
