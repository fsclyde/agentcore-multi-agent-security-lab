# Known gaps

## To confirm in the first full run

- **HolmesGPT command line:** the wrapper runs `holmes ask ... --no-interactive` and reads stdout. Check the flags against the pinned HolmesGPT version.
- **Gateway tool names in Lambda:** the tool Lambda reads `bedrockAgentCoreToolName` from the client context. Check the name format (`<target>___<tool>`) in the first log lines.
- **Cedar input checks:** the policies read `context.input.namespace`, `name` and `image`. Check that the policy engine accepts them against the tool schemas (`terraform apply` fails if not).
- **Guardrail on HolmesGPT's findings:** the triage agent checks worker answers as input, with the prompt-attack filter on. If HolmesGPT quotes the hostile annotation, the whole answer may be blocked. Check whether that is the behaviour you want, or summarise quoted content first.
- **Authorization header to the triage container:** the runtime allowlists `Authorization` so the triage agent can forward it. Check that it arrives.

## What still needs work

- **No true on-behalf-of token at the gateway.** People's tokens go to the runtimes, but tool calls use the agent's own token, so the gateway knows *which agent* calls a tool, not *for whom*. A token exchange that carries both (the person and the acting agent) is the next step.
- **Guardrails are called by the agents.** If an agent's code is changed to skip `guard.check`, nothing stops it. A gateway interceptor applying the guardrail to every tool response would close that.
- **Who did what in Kubernetes:** the EKS audit log shows the tool Lambda's role, not the agent or the person. Linking them relies on matching times.
- **Runtimes on public network mode.** Moving them into the VPC with VPC endpoints would keep agent traffic off the internet.
- **Client secrets in Terraform state.** Keep the state local or in an encrypted S3 bucket, and rotate the secrets after a rebuild.
