#!/usr/bin/env bash
# Create two lab users: alice (sre-viewer) and bob (sre-admin).
# Passwords are generated locally and written to .local/users.env (ignored by Git).
set -euo pipefail

POOL="$(terraform -chdir=infra output -raw user_pool_id)"
REGION="$(terraform -chdir=infra output -raw region)"
mkdir -p .local && : > .local/users.env && chmod 600 .local/users.env

for pair in alice:sre-viewer bob:sre-admin; do
  user="${pair%%:*}"; group="${pair##*:}"
  pass="$(openssl rand -base64 18)Aa1!"
  aws cognito-idp admin-create-user --region "$REGION" --user-pool-id "$POOL" \
    --username "$user" --message-action SUPPRESS >/dev/null
  aws cognito-idp admin-set-user-password --region "$REGION" --user-pool-id "$POOL" \
    --username "$user" --password "$pass" --permanent
  aws cognito-idp admin-add-user-to-group --region "$REGION" --user-pool-id "$POOL" \
    --username "$user" --group-name "$group"
  echo "$(echo "$user" | tr a-z A-Z)_PASSWORD='$pass'" >> .local/users.env
  echo "created $user in $group"
done
