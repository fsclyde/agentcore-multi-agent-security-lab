# AgentCore Multi-Agent Security Lab

A starter lab for a multi-agent SRE workflow using Amazon Bedrock AgentCore, HolmesGPT, and the upstream Kubernetes MCP server.

## Kubernetes MCP integration

This integration keeps the Kubernetes MCP server behind AgentCore Gateway. HolmesGPT connects to the Gateway's MCP endpoint, and Kubernetes RBAC on the server's ServiceAccount limits the resources it can read. Holmes' overlapping built-in Kubernetes toolsets remain disabled.

- [Kubernetes MCP integration guide](docs/kubernetes-mcp.md)
- [Read-only Kubernetes MCP Helm values](deploy/kubernetes-mcp/read-values.yaml)
- [Namespace-scoped Kubernetes RBAC](deploy/kubernetes-mcp/rbac.yaml)
- [HolmesGPT MCP client values](deploy/holmes/values.yaml)

The current module is read-only. It does not provision AWS resources or expose the MCP server. Before running it, configure a reachable HTTPS MCP target in AgentCore Gateway and set the Gateway endpoint in Holmes' values. The integration guide lists the remaining setup and verification steps.

## Security boundaries

- Holmes connects to Kubernetes through AgentCore Gateway as an MCP client.
- AgentCore Gateway is the policy boundary for authenticated agent access and tool authorization.
- Kubernetes RBAC is the final authorization boundary for Kubernetes API operations.
- The MCP server runs with a dedicated ServiceAccount and does not receive cluster-admin permissions.
- Secrets and live endpoint URLs are supplied by the operator and are not committed here.
