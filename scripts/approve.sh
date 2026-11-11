#!/usr/bin/env bash
# Four-eyes approval of one change, by a second sre-admin.
#
# Usage: ./scripts/approve.sh <approver> <change-id> <requester> <namespace> <deployment> <container> <image>
# e.g.   ./scripts/approve.sh carol CHG-1001 bob demo demo-web web nginxinc/nginx-unprivileged:1.27-alpine
#
# Stores a single-use approval (SecureString, 30 minutes by default) that the gateway
# interceptor checks before the write tool runs. The approver's own Cognito
# token is stored with it, so the interceptor can verify who approved and
# when; nobody can approve their own change. Writing approvals also needs IAM
# permission on /acsl/approvals/* (in production: your change-management tool).
# APPROVAL_MINUTES=0 creates an approval that has already expired (for the
# demo); the gateway refuses anything over 30 minutes.
set -euo pipefail

minutes="${APPROVAL_MINUTES:-30}"
approver="$1"; change_id="$2"; requester="$3"; ns="$4"; name="$5"; container="$6"; image="$7"
REGION="$(terraform -chdir=infra output -raw region)"
TOKEN="$(./scripts/user-token.sh "$approver")"

record="$(jq -n --arg r "$requester" --arg ns "$ns" --arg n "$name" --arg c "$container" --arg i "$image" \
  --arg t "$TOKEN" --argjson now "$(date +%s)" --argjson ttl "$(( minutes * 60 ))" \
  '{requested_by: $r, namespace: $ns, name: $n, container: $c, image: $i,
    approver_token: $t, approved_at: $now, expires: ($now + $ttl)}')"

aws ssm put-parameter --region "$REGION" --name "/acsl/approvals/${change_id}" \
  --type SecureString --value "$record" --no-overwrite >/dev/null
echo "change ${change_id} approved by ${approver} for ${requester}: ${ns}/${name} ${container}=${image} (${minutes} minutes, single use)"
