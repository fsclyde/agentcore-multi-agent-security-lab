# Identity for people and for agents.
#
# People: two users (created by scripts/create-users.sh) in two groups.
#   sre-viewer  can ask for an investigation
#   sre-admin   can also ask for a repair
#   Their access token carries a cognito:groups claim. The AgentCore runtimes
#   check that claim before they accept a request.
#
# Agents: HolmesGPT and the operator each get their own app client and use the
#   client credentials flow. In those tokens sub = client ID, so Cedar policies
#   at the gateway can name each agent.

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

resource "random_id" "domain" {
  byte_length = 4
}

resource "aws_cognito_user_pool_domain" "lab" {
  domain       = "${local.name}-${random_id.domain.hex}"
  user_pool_id = aws_cognito_user_pool.lab.id
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
  access_token_validity         = 15
  id_token_validity             = 15
  refresh_token_validity        = 1
  prevent_user_existence_errors = "ENABLED"

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}

# One scope for tool access through the gateway.
resource "aws_cognito_resource_server" "tools" {
  identifier   = "sre-tools"
  name         = "SRE tools gateway"
  user_pool_id = aws_cognito_user_pool.lab.id

  scope {
    scope_name        = "invoke"
    scope_description = "Call tools through the AgentCore gateway"
  }
}

# One machine client per agent that calls tools.
resource "aws_cognito_user_pool_client" "agent" {
  for_each = toset(["holmes", "operator"])

  name                                 = "${local.name}-agent-${each.key}"
  user_pool_id                         = aws_cognito_user_pool.lab.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["${aws_cognito_resource_server.tools.identifier}/invoke"]
  supported_identity_providers         = ["COGNITO"]
  access_token_validity                = 15

  token_validity_units {
    access_token = "minutes"
  }
}

# Each agent can read only its own client secret.
resource "aws_secretsmanager_secret" "agent" {
  for_each                = aws_cognito_user_pool_client.agent
  name                    = "${local.name}/agent/${each.key}/client-secret"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "agent" {
  for_each      = aws_cognito_user_pool_client.agent
  secret_id     = aws_secretsmanager_secret.agent[each.key].id
  secret_string = each.value.client_secret
}

locals {
  oidc_discovery_url = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.lab.id}/.well-known/openid-configuration"
  token_endpoint     = "https://${aws_cognito_user_pool_domain.lab.domain}.auth.${var.aws_region}.amazoncognito.com/oauth2/token"
}
