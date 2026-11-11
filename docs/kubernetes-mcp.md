# HolmesGPT and the Kubernetes MCP server

HolmesGPT reads the cluster through the upstream [Kubernetes MCP server](https://github.com/containers/kubernetes-mcp-server), placed behind the Amazon Bedrock AgentCore Gateway. HolmesGPT's built-in `kubernetes/core` and `kubernetes/logs` toolsets and its Bash toolset are disabled, so this is its only view of the cluster.

## Request path

```text
HolmesGPT (AgentCore Runtime, in the VPC)
  -> local signing proxy: SigV4 as the holmes role + the person's token
  -> AgentCore Gateway
       REQUEST interceptor: checks the person with Cognito
       Cedar: agent + tool + namespace + kind
       RESPONSE interceptor: guardrail on the result
  -> VPC Lattice (private) -> internal ALB (TLS, only /mcp)
  -> NodePort 30080 -> Kubernetes MCP server (read-only, tool allowlist)
  -> Kubernetes API as ServiceAccount mcp/k8s-mcp-read (RBAC: demo only, no Secrets)
```

Every layer limits the same thing in a different way:

| Layer | What it allows |
| --- | --- |
| HolmesGPT `allowed_tools` | Six read tools. Agent-side only, a convenience, not a control. |
| AgentCore Gateway + Cedar | HolmesGPT only, `namespace: demo`, and for `resources_*` only Pod, Deployment, ReplicaSet and Event. Default deny. |
| MCP server | `read_only: true` and `enabled_tools`: six tools, no writes, no exec. |
| Kubernetes RBAC | ServiceAccount `k8s-mcp-read`: get and list pods, logs, events, Deployments and ReplicaSets in `demo`. Nothing else. |
| Network | The ALB is internal, only accepts the gateway's Lattice security group, and only forwards `/mcp`. A NetworkPolicy limits the pod's traffic. |

## Files

- [deploy/kubernetes-mcp/read-values.yaml](../deploy/kubernetes-mcp/read-values.yaml): Helm values, pinned to `v0.1.2`.
- [deploy/kubernetes-mcp/rbac.yaml](../deploy/kubernetes-mcp/rbac.yaml): namespace-scoped Role and RoleBinding.
- [deploy/kubernetes-mcp/nodeport.yaml](../deploy/kubernetes-mcp/nodeport.yaml): NodePort for the internal ALB.
- [deploy/kubernetes-mcp/networkpolicy.yaml](../deploy/kubernetes-mcp/networkpolicy.yaml): ingress on the MCP port only; egress to the API and DNS.
- [infra/k8s_mcp.tf](../infra/k8s_mcp.tf): certificate, internal ALB, security groups and the private gateway target.
- [agents/holmes/holmes-config.yaml](../agents/holmes/holmes-config.yaml): HolmesGPT's MCP client settings.

Installation and checks are in steps 2, 3 and 6 of the [setup guide](setup.md).

## Why the write stays in a Lambda

The MCP server runs as one ServiceAccount for everyone. For reads, that is acceptable: only HolmesGPT uses it, and the gateway logs for whom. For the one change the operator may make, the lab keeps a small Lambda that impersonates `agent:operator` on behalf of the person, so the Kubernetes audit log itself says who changed what, for whom.
