# Known gaps

## Fixed in this version

- **On-behalf-of at the gateway.** Every tool call carries the agent (SigV4, its own IAM role) and the person (their Cognito token, checked by Cognito in the REQUEST interceptor). Cedar decides on both.
- **Guardrails enforced outside the agents.** The RESPONSE interceptor applies the guardrail to every tool result at the gateway.
- **Who did what in Kubernetes.** The write Lambda impersonates `agent:operator` with the person as `on-behalf-of`, so the audit record of every change names both.
- **Network.** The runtimes run in VPC mode and reach AWS through VPC endpoints only.
- **Secrets in state.** Agents have no client secrets any more, and the state lives in an encrypted, versioned S3 bucket.

## To confirm in the first full run

- **Kubernetes MCP server version:** the chart and image are pinned to `0.1.2` / `v0.1.2`. Check the tool names and argument names in the gateway's `tools/list` against the Cedar policies (`infra/policies.tf`) and the HolmesGPT `allowed_tools`.
- **Private MCP target:** the gateway reaches the ALB through VPC Lattice with `routing_domain`. Check that the target becomes `READY` and the ALB target is healthy.
- **IAM principal format in Cedar:** the policies name the agents as `arn:aws:sts::<account>:assumed-role/<role>`. Check the principal in the first `LOG_ONLY` decisions and adjust `infra/policies.tf` if it differs.
- **Custom headers to the interceptor:** `X-On-Behalf-Of` and `X-Agent-Name` must reach the interceptor with `pass_request_headers`. Check the first interceptor log lines.
- **HolmesGPT command line:** the wrapper runs `holmes ask ... --no-interactive` and reads stdout. Check the flags against the pinned HolmesGPT version.
- **Gateway tool names in Lambda:** the tool Lambda reads `bedrockAgentCoreToolName` from the client context. Check the name format (`<target>___<tool>`).
- **Authorization header to the containers:** each runtime allowlists `Authorization` so the agent can forward the person's token. Check that it arrives.
- **Endpoints for VPC mode:** if a runtime fails to start or times out, check its logs for an AWS service without a VPC endpoint.

## What still needs work

- **Reads are not attributed per agent in Kubernetes.** The upstream MCP server calls the API as its own ServiceAccount, so the audit log shows `k8s-mcp-read` for reads by both agents. The interceptor log records the agent and the person for every call; matching the two needs the time. One MCP server per agent, or impersonation support in the server, would close this.
- **Person checks on reads are in the interceptor, not in Cedar.** The MCP server's tool schemas don't have the identity fields, so the interceptor checks the person for reads, and Cedar decides on the agent and the inputs.
- **No authentication between the gateway and the MCP server.** It is private (Lattice to an internal ALB that only accepts the Lattice security group), but the server accepts any request that reaches it. Adding OAuth on the server (`require_oauth`) with a gateway credential provider would add one.
- **Messages between agents.** Tool results are checked at the gateway, but A2A messages between agents are still checked by the agents' own code. AgentCore has no hook between runtimes yet.
- **The person's role is coarse.** The interceptor passes one role (`sre-admin` or `sre-viewer`). Finer rules, such as which namespaces a person owns, would need more attributes from the identity provider.
- **The interceptor is a single point of trust.** Cedar and the tools rely on the identity it writes. Its code and role need the same review as the policies.
