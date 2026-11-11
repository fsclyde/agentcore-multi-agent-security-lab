# Glossary

The words this lab uses, in one line each.

| Term | What it means here |
| --- | --- |
| **Amazon Bedrock AgentCore** | AWS's service for running AI agents: hosting (Runtime), tool access (Gateway), identity and observability. |
| **AgentCore Runtime** | Where each agent's container runs. It checks the caller's token before the request reaches the agent. |
| **AgentCore Gateway** | The single door to tools. Every tool call from every agent goes through it, so the checks happen in one place the agents cannot change. |
| **Interceptor** | A Lambda function the gateway runs on every request and every response. Here it checks the person and the approval, and runs the guardrail on results. |
| **Cedar** | AWS's policy language. The gateway's policy engine uses Cedar rules to allow or deny each tool call. `LOG_ONLY` records decisions; `ENFORCE` applies them. |
| **Bedrock Guardrails** | Content filters: here they block prompt attacks and AWS keys, and mask e-mails, tokens and passwords in tool results. |
| **A2A** | Agent-to-agent protocol: how the triage agent delegates to HolmesGPT and to the operator. |
| **MCP** | Model Context Protocol: the standard way an agent lists and calls tools. The gateway speaks MCP to the agents. |
| **Kubernetes MCP server** | An open-source MCP server that exposes Kubernetes reads (pods, events, logs) as tools. Here it is read-only and limited to one namespace. |
| **HolmesGPT** | An open-source AI agent for investigating Kubernetes incidents. Here it can only read, and only through the gateway. |
| **Amazon Cognito** | Where the people (nadia, marco, priya) log in. Their group, `sre-viewer` or `sre-admin`, is in their token. |
| **On behalf of** | Every tool call carries two identities: the agent (its IAM role) and the person it works for (their Cognito token). |
| **SigV4** | AWS request signing. Each agent signs gateway calls with its own IAM role, so no agent needs a secret. |
| **Four eyes** | A change needs a second person: priya approves marco's change before it can run. |
| **Change ID** | The name of one approved change, such as `CHG-1001`. The approval is valid for that exact change, once, for 30 minutes at most. |
| **Impersonation** | A Kubernetes feature: the write Lambda acts as `agent:operator` and attaches the person, so the audit log names both. |
| **VPC Lattice** | AWS private networking between services. The gateway reaches the MCP server through it, never through the internet. |
| **VPC endpoint** | A private door from the VPC to an AWS service. The agents reach AWS only through these. |
