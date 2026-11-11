# Known gaps

## In place

- **Agent and person on every tool call.** The agent signs with its own IAM role; the person's Cognito token travels with the call and is validated at the gateway (signature, issuer, expiry, client). Cedar decides on the agent and the inputs, and on the person for changes.
- **Four-eyes changes.** A change needs an approval for exactly that change, by another `sre-admin`, single use, valid 30 minutes at most (`scripts/approve.sh`). Kubernetes records the change ID and the approver in its audit log and in the rollout history. The session of the person asking is checked live with Cognito, so a sign-out stops changes at once.
- **Guardrails enforced outside the agents** on every tool result, at the gateway.
- **Least privilege per agent.** HolmesGPT reads through the Kubernetes MCP server (read-only, `demo` only, no Secrets); the operator has one write tool and no reads. The write runs as `agent:operator` on behalf of the person, so the audit log names both.
- **Short-lived credentials only.** No agent secrets; people's tokens last 5 minutes.
- **Private network path.** Runtimes in the VPC, VPC endpoints, VPC Lattice to an internal load balancer.
- **Limits.** The write tool runs one change at a time; model answers are capped in tokens.
- **Saved queries** for every attempt at a change in order, denials, writes with their approver, guardrail interventions and calls per person.

## To confirm in the first full run

- **Kubernetes MCP server version:** the chart and image are pinned to `0.1.2` / `v0.1.2`. Check the tool names and argument names in the gateway's `tools/list` against the Cedar policies (`infra/policies.tf`) and the HolmesGPT `allowed_tools`.
- **Private MCP target:** the gateway reaches the ALB through VPC Lattice with `routing_domain`. Check that the target becomes `READY` and the ALB target is healthy.
- **IAM principal format in Cedar:** the policies name the agents as `arn:aws:sts::<account>:assumed-role/<role>`. Check the principal in the first `LOG_ONLY` decisions and adjust `infra/policies.tf` if it differs.
- **Custom headers to the interceptor:** `X-On-Behalf-Of` and `X-Agent-Name` must reach the interceptor with `pass_request_headers`. Check the first interceptor log lines.
- **HolmesGPT command line:** the wrapper runs `holmes ask ... --no-interactive` and reads stdout. Check the flags against the pinned HolmesGPT version.
- **Gateway tool names in Lambda:** the tool Lambda reads `bedrockAgentCoreToolName` from the client context. Check the name format (`<target>___<tool>`).
- **Authorization header to the containers:** each runtime allowlists `Authorization` so the agent can forward the person's token. Check that it arrives.
- **Endpoints for VPC mode:** if a runtime fails to start or times out, check its logs for an AWS service without a VPC endpoint.
- **Guardrail false positives:** prompt-attack filtering on tool results can block real investigations. Watch the `guardrail` saved query during the first runs before relying on it.

## Would add infrastructure cost

| Gap | What production needs | Why it costs |
| --- | --- | --- |
| Single node, single replica | Two or more nodes across zones, two MCP server replicas, PodDisruptionBudgets, autoscaling | More EC2 instances |
| Single NAT gateway | One NAT gateway per zone | Hourly charge per NAT gateway |
| One account for everything | Agents and gateway in a platform account, each workload cluster in its own account, Lattice shared through AWS RAM | VPC endpoints, NAT and load balancer in each account |
| No alerting | Metric filters and CloudWatch alarms on denials, writes and guardrail blocks, sent to a SIEM | Custom metrics and alarms are billed monthly; SIEM ingestion |
| Logs kept 7 days | 90 days or more, with CloudTrail data events for AgentCore | Log storage and CloudTrail data events |
| One MCP server for all reads | One MCP server per workload cluster or team, each with its own ServiceAccount | More pods, target groups and capacity |
| Signed, scanned images | Image signing (cosign) and admission checks for the agent and MCP images | Signing keys (KMS) and an admission controller to run |

## No extra cost, but outside the lab

- **True token exchange.** People's tokens are forwarded, with 5-minute lifetimes to limit replay. Production should exchange them at each hop for a narrower token for the next service, carrying both the person and the acting agent (RFC 8693). Cognito does not support token exchange: this needs an identity provider that does, or AgentCore Identity once it covers this flow.
- **Corporate identity provider.** People should log in through Okta or Entra ID (federated into Cognito or used directly), with SRE groups managed there instead of by script.
- **Change management.** Approvals are SSM parameters written by script. In production they come from your change tool (ServiceNow, Jira, a Slack approval), with the same rules: another person, exactly this change, single use, short expiry.
- **Authentication between the gateway and the MCP server.** The path is private, but the server accepts any request that reaches it. Turning on `require_oauth` on the server with a gateway credential provider would add a check.
- **Messages between agents.** Tool results are checked at the gateway, but A2A messages between agents are still checked by the agents' own code. AgentCore has no hook between runtimes yet.
- **Coarse roles.** The interceptor passes `sre-admin` or `sre-viewer`. Finer rules, such as which namespaces a person owns, need more attributes from the identity provider.
- **The interceptor is a single point of trust.** Cedar and the write tool rely on the identity it writes. Its code and role need the same review and tests as the policies.
- **Reads are attributed to the MCP server in Kubernetes.** Only HolmesGPT uses it, so the agent is known; the person is in the interceptor log, not the audit log.
