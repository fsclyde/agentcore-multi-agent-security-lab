#!/usr/bin/env bash
# Send a request to the triage agent as alice or bob.
# Usage: ./scripts/ask.sh bob "Investigate demo-web in namespace demo"
set -euo pipefail

user="$1"; prompt="$2"
REGION="$(terraform -chdir=infra output -raw region)"
ARN="$(terraform -chdir=infra output -json runtime_arns | jq -r '.triage')"
URL="https://bedrock-agentcore.${REGION}.amazonaws.com/runtimes/$(jq -rn --arg a "$ARN" '$a|@uri')/invocations?qualifier=DEFAULT"
TOKEN="$(./scripts/user-token.sh "$user")"

curl -sS -X POST "$URL" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: lab-$(uuidgen | tr -d -)-$(date +%s)" \
  -d "$(jq -n --arg p "$prompt" '{prompt: $p}')" \
  -w "\nHTTP %{http_code}\n"
