#!/usr/bin/env bash
# Create or update infra/terraform.tfvars (ignored by Git):
#   - admin_cidr: your current public IP
#   - mcp_domain: a public Route 53 hosted zone in this account, for the
#     Kubernetes MCP server's TLS certificate
#
# With one public hosted zone, it is picked automatically. With several, set
# MCP_DOMAIN to choose one. Safe to run again: it only changes these two lines.
#
# Usage: ./scripts/configure.sh            or   MCP_DOMAIN=lab.example.com ./scripts/configure.sh
set -euo pipefail

TFVARS=infra/terraform.tfvars
[[ -f "$TFVARS" ]] || cp infra/terraform.tfvars.example "$TFVARS"

set_var() {  # set_var name value: replace the line if present, append otherwise
  local name="$1" value="$2"
  if grep -qE "^${name}[[:space:]]*=" "$TFVARS"; then
    sed -i.bak -E "s|^${name}[[:space:]]*=.*|${name} = \"${value}\"|" "$TFVARS" && rm -f "$TFVARS.bak"
  else
    echo "${name} = \"${value}\"" >> "$TFVARS"
  fi
  echo "  ${name} = \"${value}\""
}

echo "Writing ${TFVARS}:"
set_var admin_cidr "$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')/32"

zones="$(aws route53 list-hosted-zones \
  --query 'HostedZones[?Config.PrivateZone==`false`].Name' --output text | tr '\t' '\n' | sed 's/\.$//' | sed '/^$/d')"
count="$(printf '%s\n' "$zones" | sed '/^$/d' | wc -l | tr -d ' ')"

if [[ -n "${MCP_DOMAIN:-}" ]]; then
  domain="${MCP_DOMAIN%.}"
  printf '%s\n' "$zones" | grep -qx "$domain" || { echo "MCP_DOMAIN=${domain} is not a public hosted zone in this account. Zones found:"; printf '  %s\n' $zones; exit 1; }
elif [[ "$count" == 1 ]]; then
  domain="$zones"
elif [[ "$count" == 0 ]]; then
  echo "No public Route 53 hosted zone in this account. Create one for a domain you own, then run this again."
  exit 1
else
  echo "Several public hosted zones. Choose one and run again, for example:"
  printf '  MCP_DOMAIN=%s ./scripts/configure.sh\n' $zones
  exit 1
fi

set_var mcp_domain "$domain"
echo "The MCP server's certificate will be for acsl-mcp.${domain}. Nothing is published there: the gateway reaches it privately."
