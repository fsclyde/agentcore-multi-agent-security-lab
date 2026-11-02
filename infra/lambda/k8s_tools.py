"""Kubernetes tools behind the AgentCore gateway.

One file, two Lambda functions:
  MODE=READ   list_pods, get_deployment, get_events, get_pod_logs
  MODE=WRITE  update_deployment_image

Each function has its own IAM role, mapped by an EKS access entry to its own
Kubernetes group. RBAC (manifests/rbac.yaml) decides what that group may do,
so a read function cannot write even if a gateway policy were wrong.

The EKS token is a presigned STS GetCallerIdentity URL (what aws eks get-token
does). Signing is local, so the function needs no internet access. Only the
standard library and boto3 (included in the Lambda runtime) are used.
"""

import base64
import json
import os
import ssl
import tempfile
import urllib.error
import urllib.request

import boto3

MODE = os.environ["MODE"]
CLUSTER = os.environ["CLUSTER_NAME"]
ENDPOINT = os.environ["API_ENDPOINT"].rstrip("/")
REGION = os.environ["AWS_REGION"]

_ca_file = tempfile.NamedTemporaryFile(delete=False, suffix=".crt")
_ca_file.write(base64.b64decode(os.environ["CLUSTER_CA"]))
_ca_file.close()
_ssl = ssl.create_default_context(cafile=_ca_file.name)

READ_TOOLS = {"list_pods", "get_deployment", "get_events", "get_pod_logs"}
WRITE_TOOLS = {"update_deployment_image"}


def _eks_token() -> str:
    sts = boto3.client("sts", region_name=REGION, endpoint_url=f"https://sts.{REGION}.amazonaws.com")

    def add_cluster_header(request, **_):
        request.headers["x-k8s-aws-id"] = CLUSTER

    sts.meta.events.register("before-sign.sts.GetCallerIdentity", add_cluster_header)
    url = sts.generate_presigned_url("get_caller_identity", Params={}, ExpiresIn=60, HttpMethod="GET")
    return "k8s-aws-v1." + base64.urlsafe_b64encode(url.encode()).decode().rstrip("=")


def _k8s(method: str, path: str, body=None, content_type="application/json", raw=False):
    req = urllib.request.Request(
        ENDPOINT + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {_eks_token()}", "Content-Type": content_type, "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, context=_ssl, timeout=15) as resp:
            data = resp.read().decode()
            return data if raw else json.loads(data)
    except urllib.error.HTTPError as err:
        # Return the Kubernetes answer (403 forbidden, 404 not found) to the agent.
        return {"error": f"Kubernetes API returned {err.code}", "detail": err.read().decode()[:500]}


def list_pods(namespace):
    data = _k8s("GET", f"/api/v1/namespaces/{namespace}/pods")
    if "error" in data:
        return data
    pods = []
    for p in data.get("items", []):
        statuses = p.get("status", {}).get("containerStatuses", [])
        pods.append({
            "name": p["metadata"]["name"],
            "phase": p.get("status", {}).get("phase"),
            "images": [c["image"] for c in p["spec"]["containers"]],
            "waiting": [s["state"]["waiting"].get("reason") for s in statuses if "waiting" in s.get("state", {})],
            "restarts": sum(s.get("restartCount", 0) for s in statuses),
        })
    return {"pods": pods}


def get_deployment(namespace, name):
    d = _k8s("GET", f"/apis/apps/v1/namespaces/{namespace}/deployments/{name}")
    if "error" in d:
        return d
    return {
        "name": name,
        "annotations": d["metadata"].get("annotations", {}),
        "replicas": d["spec"].get("replicas"),
        "available": d.get("status", {}).get("availableReplicas", 0),
        "containers": [{"name": c["name"], "image": c["image"]} for c in d["spec"]["template"]["spec"]["containers"]],
        "conditions": [{"type": c["type"], "status": c["status"], "message": c.get("message")}
                       for c in d.get("status", {}).get("conditions", [])],
    }


def get_events(namespace):
    data = _k8s("GET", f"/api/v1/namespaces/{namespace}/events")
    if "error" in data:
        return data
    items = sorted(data.get("items", []), key=lambda e: e.get("lastTimestamp") or "", reverse=True)[:20]
    return {"events": [{"type": e.get("type"), "reason": e.get("reason"),
                        "object": e.get("involvedObject", {}).get("name"), "message": e.get("message")} for e in items]}


def get_pod_logs(namespace, pod):
    out = _k8s("GET", f"/api/v1/namespaces/{namespace}/pods/{pod}/log?tailLines=50", raw=True)
    return out if isinstance(out, dict) else {"logs": out}


def update_deployment_image(namespace, name, container, image):
    patch = {"spec": {"template": {"spec": {"containers": [{"name": container, "image": image}]}}}}
    d = _k8s("PATCH", f"/apis/apps/v1/namespaces/{namespace}/deployments/{name}", patch,
             content_type="application/strategic-merge-patch+json")
    if "error" in d:
        return d
    return {"updated": name, "container": container, "image": image}


TOOLS = {f.__name__: f for f in (list_pods, get_deployment, get_events, get_pod_logs, update_deployment_image)}


def handler(event, context):
    # The gateway passes the tool name as "<target>___<tool>" in the client context.
    full_name = context.client_context.custom["bedrockAgentCoreToolName"]
    tool = full_name.split("___", 1)[-1]

    allowed = READ_TOOLS if MODE == "READ" else WRITE_TOOLS
    if tool not in allowed:
        return {"error": f"{tool} is not available on this target"}

    print(json.dumps({"tool": tool, "input": event}))  # audit line in CloudWatch Logs
    return TOOLS[tool](**event)
