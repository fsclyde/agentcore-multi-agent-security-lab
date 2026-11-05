#!/usr/bin/env python3
"""Checks the controls without calling a model (no Bedrock model cost).

Gateway checks act as each agent: the script assumes the agent's IAM role
(allow_test_assume = true) and signs MCP requests with it, attaching alice's
(sre-viewer) or bob's (sre-admin) token, exactly as the agents do.

Run from the repo root after `terraform apply`:  python3 scripts/checks.py
"""

import json
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.credentials import Credentials


def tf(name):
    return json.loads(subprocess.check_output(["terraform", "-chdir=infra", "output", "-json", name]))


REGION = tf("region")
GATEWAY = tf("gateway_url")
ROLES = tf("agent_role_arns")
RUNTIMES = tf("runtime_arns")
results = []


def person(user):
    return subprocess.check_output(["./scripts/user-token.sh", user]).decode().strip()


def agent_credentials(agent):
    c = boto3.client("sts", region_name=REGION).assume_role(RoleArn=ROLES[agent], RoleSessionName=f"checks-{agent}")
    c = c["Credentials"]
    return Credentials(c["AccessKeyId"], c["SecretAccessKey"], c["SessionToken"])


CREDS = {a: agent_credentials(a) for a in ("holmes", "operator")}


def http(url, body, headers):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            status, raw = r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read().decode()
    if raw.startswith(("event:", "data:")):  # streamable HTTP may answer as SSE
        raw = "".join(line[5:] for line in raw.splitlines() if line.startswith("data:"))
    return status, raw


def gateway(agent, method, params, bearer=None, claim_name=None, signed=True):
    body = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
               "X-Agent-Name": claim_name or agent}
    if bearer:
        headers["X-On-Behalf-Of"] = f"Bearer {bearer}"
    if signed:
        req = AWSRequest(method="POST", url=GATEWAY, data=json.dumps(body), headers=headers)
        SigV4Auth(CREDS[agent], "bedrock-agentcore", REGION).add_auth(req)
        headers = dict(req.headers)
    return http(GATEWAY, body, headers)


def call(agent, tool, args, bearer, **kw):
    status, raw = gateway(agent, "tools/call", {"name": tool, "arguments": args}, bearer, **kw)
    try:
        body = json.loads(raw)
    except ValueError:
        return f"HTTP {status}"
    res = body.get("result", {})
    text = " ".join(c.get("text", "") for c in res.get("content", []))
    if status != 200 or "error" in body or res.get("isError"):
        return "DENIED: " + (text or json.dumps(body.get("error")))[:120]
    if "error" in text[:40]:  # the tool ran and Kubernetes refused
        return "DENIED by Kubernetes: " + text[:100]
    return "ALLOWED: " + text[:80]


def check(label, got, expect):
    ok = got.startswith(expect)
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {label}\n      {got[:150]}")


alice, bob = person("alice"), person("bob")
R, W = "k8s-read___", "k8s-write___update_deployment_image"
read = {"namespace": "demo", "name": "demo-web"}
fix = {"namespace": "demo", "name": "demo-web", "container": "web", "image": "nginxinc/nginx-unprivileged:1.27-alpine"}

print("Gateway: who is calling")
check("Unsigned request", f"HTTP {gateway('holmes', 'tools/list', {}, signed=False)[0]}", "HTTP 40")
check("HolmesGPT without a person", call("holmes", R + "get_deployment", read, None), "DENIED")
check("HolmesGPT for alice, reads demo", call("holmes", R + "get_deployment", read, alice), "ALLOWED")
check("HolmesGPT claims to be the operator", call("holmes", W, fix, bob, claim_name="operator"), "DENIED")

print("Gateway: what it may do")
check("HolmesGPT reads kube-system", call("holmes", R + "list_pods", {"namespace": "kube-system"}, alice), "DENIED")
check("HolmesGPT calls the write tool for bob", call("holmes", W, fix, bob), "DENIED")
check("Operator writes for alice (viewer)", call("operator", W, fix, alice), "DENIED")
check("Operator writes kube-system for bob", call("operator", W, {**fix, "namespace": "kube-system", "name": "coredns", "container": "coredns"}, bob), "DENIED")
check("Operator sets an unapproved image for bob", call("operator", W, {**fix, "image": "evil/miner:latest"}, bob), "DENIED")

print("Gateway: guardrail on tool results")
check("E-mail in an annotation is masked", call("holmes", R + "get_deployment", read, alice), "ALLOWED")
print("      (look for {EMAIL} instead of oncall@example.com in the line above)")

if RUNTIMES:
    print("Delegation: the runtime checks the person's group")

    def runtime(arn, token):
        url = f"https://bedrock-agentcore.{REGION}.amazonaws.com/runtimes/{urllib.parse.quote(arn, safe='')}/invocations/"
        status, _ = http(url, {"jsonrpc": "2.0", "id": 1, "method": "ping"},
                         {"Content-Type": "application/json", "Authorization": f"Bearer {token}",
                          "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id": str(uuid.uuid4()) * 2})
        return f"HTTP {status}"

    check("alice (viewer) -> operator", runtime(RUNTIMES["operator"], alice), "HTTP 40")
    check("alice (viewer) -> HolmesGPT", runtime(RUNTIMES["holmes"], alice), "HTTP 200")
    check("bob (admin) -> operator", runtime(RUNTIMES["operator"], bob), "HTTP 200")

print(f"\n{sum(results)}/{len(results)} checks passed")
sys.exit(0 if all(results) else 1)
