#!/usr/bin/env bash
# Print a 5-minute access token for alice, bob or carol.
# Usage: TOKEN=$(./scripts/user-token.sh alice)
set -euo pipefail

user="$1"
source .local/users.env
var="$(echo "$user" | tr a-z A-Z)_PASSWORD"

aws cognito-idp initiate-auth --region "$(terraform -chdir=infra output -raw region)" \
  --client-id "$(terraform -chdir=infra output -raw user_client_id)" \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=${user},PASSWORD=${!var}" \
  --query AuthenticationResult.AccessToken --output text
