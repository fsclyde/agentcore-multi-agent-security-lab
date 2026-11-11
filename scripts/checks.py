#!/usr/bin/env python3
"""Checks the controls without calling a model (no Bedrock model cost).

Gateway checks act as each agent: the script assumes the agent's IAM role
(allow_test_assume = true) and signs MCP requests with it, attaching nadia's
(sre-viewer) or marco's (sre-admin) token, exactly as the agents do. Changes are
approved by priya with scripts/approve.sh, so the checks can reach the policy
behind the approval. The checks only ever write the correct image or an image
that cannot be pulled.

Read tools come from the upstream Kubernetes MCP server (target k8s-mcp);
the write tool is the Lambda (target k8s-write).

Run from the repo root after `terraform apply`:  python3 scripts/checks.py
Only the approval checks (setup step 9):           python3 scripts/checks.py approvals
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import time
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


nadia, marco = person("nadia"), person("marco")
R, W = "k8s-mcp___", "k8s-write___update_deployment_image"
read = {"apiVersion": "apps/v1", "kind": "Deployment", "namespace": "demo", "name": "demo-web"}
GOOD = "nginxinc/nginx-unprivileged:1.27-alpine"
BAD = "evil.example.invalid/miner:latest"  # unresolvable on purpose
_n = [0]


def approved(change, approver="priya", requester="marco", minutes=30):
    """Creates a four-eyes approval for exactly this change and returns the args with its ID."""
    _n[0] += 1
    cid = f"CHK-{int(time.time())}-{_n[0]}"
    subprocess.run(["./scripts/approve.sh", approver, cid, requester, change["namespace"], change["name"],
                    change["container"], change["image"]], check=True, capture_output=True,
                   env={**os.environ, "APPROVAL_MINUTES": str(minutes)})
    return {**change, "change_id": cid}


fix = {"namespace": "demo", "name": "demo-web", "container": "web", "image": GOOD}
ONLY = set(sys.argv[1:])  # e.g. {"approvals"}


def section(name, title):
    if ONLY and name not in ONLY:
        return False
    print(title)
    return True


if section("identity", "Gateway: who is calling"):
    check("Unsigned request", f"HTTP {gateway('holmes', 'tools/list', {}, signed=False)[0]}", "HTTP 40")
    check("HolmesGPT without a person", call("holmes", R + "resources_get", read, None), "DENIED")
    check("HolmesGPT with a forged person token", call("holmes", R + "resources_get", read, nadia[:-8] + "AAAAAAAA"), "DENIED")
    check("HolmesGPT for nadia, reads demo", call("holmes", R + "resources_get", read, nadia), "ALLOWED")
    check("HolmesGPT claims to be the operator (approved change)", call("holmes", W, approved(fix), marco, claim_name="operator"), "DENIED")

if section("reads", "Gateway: what it may read"):
    check("HolmesGPT reads kube-system", call("holmes", R + "pods_list_in_namespace", {"namespace": "kube-system"}, nadia), "DENIED")
    check("HolmesGPT reads a Secret in demo", call("holmes", R + "resources_get", {**read, "apiVersion": "v1", "kind": "Secret", "name": "any"}, nadia), "DENIED")
    check("HolmesGPT reads events without a namespace", call("holmes", R + "events_list", {}, nadia), "DENIED")
    check("Operator reads (it has no read tools)", call("operator", R + "resources_get", read, marco), "DENIED")

if section("approvals", "Gateway: changes need a second sre-admin"):
    check("Write without a change ID", call("operator", W, fix, marco), "DENIED")
    check("Write approved by the requester himself", call("operator", W, approved(fix, approver="marco"), marco), "DENIED")
    check("Write with an expired approval", call("operator", W, approved(fix, minutes=0), marco), "DENIED")
    check("Write that differs from the approval", call("operator", W, {**approved(fix), "image": "nginxinc/nginx-unprivileged:1.26"}, marco), "DENIED")
    check("Operator writes for nadia (viewer)", call("operator", W, approved(fix, requester="nadia"), nadia), "DENIED")
    check("HolmesGPT calls the write tool (approved change)", call("holmes", W, approved(fix), marco), "DENIED")
    check("Operator writes kube-system (approved change)", call("operator", W, approved({**fix, "namespace": "kube-system", "name": "coredns", "container": "coredns"}), marco), "DENIED")
    check("Operator sets an unapproved image (approved change)", call("operator", W, approved({**fix, "image": BAD}), marco), "DENIED")
    reuse = approved(fix)
    call("operator", W, reuse, marco)
    check("The same approval used twice", call("operator", W, reuse, marco), "DENIED")

if section("guardrail", "Gateway: guardrail on tool results"):
    check("E-mail in an annotation is masked", call("holmes", R + "resources_get", read, nadia), "ALLOWED")
    print("      (look for {EMAIL} instead of oncall@example.com in the line above)")

if RUNTIMES and section("delegation", "Delegation: the runtime checks the person's group"):

    def runtime(arn, token):
        url = f"https://bedrock-agentcore.{REGION}.amazonaws.com/runtimes/{urllib.parse.quote(arn, safe='')}/invocations/"
        status, _ = http(url, {"jsonrpc": "2.0", "id": 1, "method": "ping"},
                         {"Content-Type": "application/json", "Authorization": f"Bearer {token}",
                          "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id": str(uuid.uuid4()) * 2})
        return f"HTTP {status}"

    check("nadia (viewer) -> operator", runtime(RUNTIMES["operator"], nadia), "HTTP 40")
    check("nadia (viewer) -> HolmesGPT", runtime(RUNTIMES["holmes"], nadia), "HTTP 200")
    check("marco (admin) -> operator", runtime(RUNTIMES["operator"], marco), "HTTP 200")

print(f"\n{sum(results)}/{len(results)} checks passed")
sys.exit(0 if all(results) else 1)
