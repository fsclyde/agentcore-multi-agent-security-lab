# HolmesGPT and Kubernetes MCP

This lab connects HolmesGPT to the upstream [Kubernetes MCP server](https://github.com/containers/kubernetes-mcp-server) through Amazon Bedrock AgentCore Gateway.

HolmesGPT's [Kubernetes MCP integration](https://holmesgpt.dev/latest/data-sources/builtin-toolsets/kubernetes-mcp/) replaces the overlapping built-in `kubernetes/core` and `kubernetes/logs` toolsets. This lab uses Holmes' remote `mcp_servers` client configuration so the MCP request goes to AgentCore Gateway, where identity and tool policies can be applied.

## Request path

```text
HolmesGPT
  -> AgentCore Gateway MCP endpoint (authentication and policy)
  -> Kubernetes MCP server (streamable HTTP)
  -> Kubernetes API (dedicated ServiceAccount and namespace-scoped RBAC)
```

The Gateway endpoint must be reachable from HolmesGPT and configured as an MCP target. The server endpoint must be reachable from AgentCore Gateway over HTTPS, using a network path supported by the chosen Gateway target configuration. Do not expose an unauthenticated MCP server to the public internet.

Kubernetes RBAC remains in force even when a Gateway policy permits a tool call. The included server is read-only and scoped to the `demo` namespace. It has no permission to read Secrets, change resources, execute commands in pods, or access other namespaces.

## Install the MCP server in Kubernetes

Create the `mcp` and `demo` namespaces, then apply the RBAC:

```bash
kubectl create namespace mcp --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace demo --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f deploy/kubernetes-mcp/rbac.yaml
```

Install the pinned upstream chart and image:

```bash
helm upgrade --install kubernetes-mcp-read \
  oci://ghcr.io/containers/charts/kubernetes-mcp-server \
  --version 0.1.2 --namespace mcp \
  --values deploy/kubernetes-mcp/read-values.yaml \
  --wait --timeout 5m
```

The chart and image are pinned to the upstream `v0.1.2` release. The MCP server has a server-side `enabled_tools` allowlist and `read_only: true`; the matching Holmes `allowed_tools` list limits which tools Holmes can request. Review the [upstream configuration reference](https://github.com/containers/kubernetes-mcp-server/blob/v0.1.2/docs/configuration.md) before changing toolsets, OAuth behavior, or access control.

## Configure HolmesGPT

Set `url` in [deploy/holmes/values.yaml](../deploy/holmes/values.yaml) to the MCP endpoint exposed by AgentCore Gateway. Configure Holmes' caller credentials using the authentication mechanism enabled on that Gateway. Do not put client secrets or bearer tokens in the values file.

The values file disables Holmes' built-in Kubernetes toolsets and restricts the remote server's visible tools. Treat `allowed_tools` as an agent-side guardrail; Gateway policy and Kubernetes RBAC must independently enforce authorization.

## Gateway target and policy

Create an AgentCore Gateway target for the Kubernetes MCP server using the supported MCP target setup for your account and network topology. Configure authentication on the Gateway, and apply per-agent policies so only the investigator can call the read tools. Keep the target endpoint private where possible and require TLS. Keep the ServiceAccount's Kubernetes permissions namespace-scoped.

This repository does not yet include AWS Gateway resources or endpoint exposure/network connectivity configuration. Those depend on the selected AWS account, region, VPC topology, and authentication provider. Supply those values through infrastructure configuration rather than hard-coding them in this lab.

## Verify the security boundary

After deploying the Gateway target and Holmes:

1. Confirm the MCP server pod uses ServiceAccount `k8s-mcp-read`.
2. Confirm the Gateway exposes only the expected read tools to the investigator identity.
3. Check that `kubectl auth can-i` allows reads in `demo`.
4. Check that reads in other namespaces and Secret reads are denied.
5. Attempt a write tool call; confirm it is absent or denied by the Gateway and denied by Kubernetes RBAC.
6. Inspect the Kubernetes audit log and Gateway logs for the test calls.

Use fake workloads and non-sensitive data during the exercise. Do not connect the lab to a production cluster.
