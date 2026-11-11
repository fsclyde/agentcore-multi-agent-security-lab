# Identity for people.
#
# Two users (created by scripts/create-users.sh) in two groups:
#   sre-viewer  can ask for an investigation
#   sre-admin   can also ask for a repair
# Their access token carries a cognito:groups claim. A third user, priya
# (sre-admin), approves changes: nobody can approve their own change.
#
# Agents do not get Cognito clients or client secrets. Each agent proves who it
# is with its own IAM role (SigV4) when it calls the gateway, so there is no
# agent secret anywhere, including in the Terraform state.

resource "aws_cognito_user_pool" "lab" {
  name = "${local.name}-pool"

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  password_policy {
    minimum_length    = 14
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }
}

resource "aws_cognito_user_group" "viewer" {
  name         = "sre-viewer"
  user_pool_id = aws_cognito_user_pool.lab.id
  description  = "Can ask the SRE agents to investigate."
}

resource "aws_cognito_user_group" "admin" {
  name         = "sre-admin"
  user_pool_id = aws_cognito_user_pool.lab.id
  description  = "Can ask the SRE agents to investigate and to repair."
}

# Client the people log in with (CLI login for the lab, no secret).
resource "aws_cognito_user_pool_client" "user" {
  name                          = "${local.name}-user-cli"
  user_pool_id                  = aws_cognito_user_pool.lab.id
  generate_secret               = false
  explicit_auth_flows           = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  access_token_validity         = 5 # the minimum: limits replay of a forwarded token
  id_token_validity             = 5
  refresh_token_validity        = 1
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}

locals {
  oidc_discovery_url = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.lab.id}/.well-known/openid-configuration"
}
