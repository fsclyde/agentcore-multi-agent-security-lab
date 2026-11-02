#!/usr/bin/env python3
"""Checks the controls without calling a model (no Bedrock cost).

Gateway checks use each agent's own token, exactly as the agents do.
Runtime checks use alice's (sre-viewer) and bob's (sre-admin) tokens.

Run from the repo root after `terraform apply`:  python3 scripts/checks.py
"""

import json
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
import base64

import boto3


def tf(name):
    return json.loads(subprocess.check_output(["terraform", "-chdir=infra", "output", "-json", name]))


REGION = tf("region")
GATEWAY = tf("gateway_url")
CLIENTS = tf("agent_client_ids")
TOKEN_URL = tf("token_endpoint")
RUNTIMES = tf("runtime_arns")
sm = boto3.client("secretsmanager", region_name=REGION)
results = []


def agent_token(agent):
    secret = sm.get_secret_value(SecretId=f"acsl/agent/{agent}/client-secret")["SecretString"]
    basic = base64.b64encode(f"{CLIENTS[agent]}:{secret}".encode()).decode()
    req = urllib.request.Request(TOKEN_URL, data=b"grant_type=client_credentials&scope=sre-tools/invoke",
                                 headers={"Authorization": f"Basic {basic}",
                                          "Content-Type": "application/x-www-form-urlencoded"})
    return json.loads(urllib.request.urlopen(req).read())["access_token"]


def post(url, body, token, extra=None):
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    headers.update(extra or {})
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read().decode()
            status = r.status
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    # Streamable HTTP may answer as an SSE event
    if raw.startswith("event:") or raw.startswith("data:"):
        raw = "".join(l[5:] for l in raw.splitlines() if l.startswith("data:"))
    return status, raw


def mcp(token, method, params=None):
    return post(GATEWAY, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}, token)


def call_tool(token, name, args):
    status, raw = mcp(token, "tools/call", {"name": name, "arguments": args})
    if status != 200:
        return f"HTTP {status}"
    body = json.loads(raw)
    res = body.get("result", {})
    text = " ".join(c.get("text", "") for c in res.get("content", []))
    if res.get("isError") or "error" in body:
        return "DENIED: " + (text or json.dumps(body.get("error")))[:120]
    return "ALLOWED: " + text[:80]


def check(label, got, expect):
    ok = got.startswith(expect)
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {label}\n      {got[:140]}")


holmes, operator = agent_token("holmes"), agent_token("operator")
w = "k8s-write___update_deployment_image"
fix = {"namespace": "demo", "name": "demo-web", "container": "web", "image": "nginxinc/nginx-unprivileged:1.27-alpine"}

print("Gateway")
check("No token -> refused", f"HTTP {mcp(None, 'tools/list')[0]}", "HTTP 401")
for agent, token in (("HolmesGPT", holmes), ("Operator", operator)):
    tools = sorted(t["name"] for t in json.loads(mcp(token, "tools/list")[1]).get("result", {}).get("tools", []))
    print(f"      {agent} sees: {tools}")
check("HolmesGPT reads demo", call_tool(holmes, "k8s-read___get_deployment", {"namespace": "demo", "name": "demo-web"}), "ALLOWED")
check("HolmesGPT reads kube-system", call_tool(holmes, "k8s-read___list_pods", {"namespace": "kube-system"}), "DENIED")
check("HolmesGPT calls the write tool", call_tool(holmes, w, fix), "DENIED")
check("Operator writes kube-system", call_tool(operator, w, {**fix, "namespace": "kube-system", "name": "coredns", "container": "coredns"}), "DENIED")
check("Operator sets an unapproved image", call_tool(operator, w, {**fix, "image": "evil/miner:latest"}), "DENIED")

if RUNTIMES:
    print("Delegation (runtime authorizer, no model call: empty A2A method)")
    alice = subprocess.check_output(["./scripts/user-token.sh", "alice"]).decode().strip()
    bob = subprocess.check_output(["./scripts/user-token.sh", "bob"]).decode().strip()

    def runtime(arn, token):
        url = f"https://bedrock-agentcore.{REGION}.amazonaws.com/runtimes/{urllib.parse.quote(arn, safe='')}/invocations/"
        status, _ = post(url, {"jsonrpc": "2.0", "id": 1, "method": "ping"}, token,
                         {"X-Amzn-Bedrock-AgentCore-Runtime-Session-Id": str(uuid.uuid4()) * 2})
        return f"HTTP {status}"

    check("alice (viewer) -> operator", runtime(RUNTIMES["operator"], alice), "HTTP 40")
    check("alice (viewer) -> HolmesGPT", runtime(RUNTIMES["holmes"], alice), "HTTP 200")
    check("bob (admin) -> operator", runtime(RUNTIMES["operator"], bob), "HTTP 200")

print(f"\n{sum(results)}/{len(results)} checks passed")
sys.exit(0 if all(results) else 1)
