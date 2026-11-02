# AgentCore Gateway: the only way the agents reach the cluster.
# Inbound: Cognito tokens from the two agent clients only.
# Every tools/call is checked by the Cedar policy engine (policies.tf).

data "aws_iam_policy_document" "agentcore_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "gateway" {
  name               = "${local.name}-gateway"
  assume_role_policy = data.aws_iam_policy_document.agentcore_assume.json
}

data "aws_iam_policy_document" "gateway" {
  statement {
    sid       = "InvokeToolLambdas"
    actions   = ["lambda:InvokeFunction"]
    resources = [for f in aws_lambda_function.tool : f.arn]
  }

  # Needed for the policy engine to authorize tool calls and filter tools/list.
  statement {
    sid = "PolicyEngine"
    actions = [
      "bedrock-agentcore:AuthorizeAction",
      "bedrock-agentcore:PartiallyAuthorizeActions",
      "bedrock-agentcore:GetPolicyEngine",
    ]
    resources = [
      aws_bedrockagentcore_policy_engine.lab.policy_engine_arn,
      "arn:aws:bedrock-agentcore:${var.aws_region}:${local.account_id}:gateway/*",
    ]
  }
}

resource "aws_iam_role_policy" "gateway" {
  name   = "gateway"
  role   = aws_iam_role.gateway.id
  policy = data.aws_iam_policy_document.gateway.json
}

resource "aws_bedrockagentcore_gateway" "tools" {
  name            = "${local.name}-sre-tools"
  description     = "Kubernetes tools for the SRE agents"
  role_arn        = aws_iam_role.gateway.arn
  protocol_type   = "MCP"
  authorizer_type = "CUSTOM_JWT"

  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url   = local.oidc_discovery_url
      allowed_clients = [for c in aws_cognito_user_pool_client.agent : c.id]
      allowed_scopes  = ["${aws_cognito_resource_server.tools.identifier}/invoke"]
    }
  }

  policy_engine_configuration {
    arn  = aws_bedrockagentcore_policy_engine.lab.policy_engine_arn
    mode = var.policy_mode
  }

  depends_on = [aws_iam_role_policy.gateway]
}

resource "aws_bedrockagentcore_gateway_target" "read" {
  name               = local.tools.read.target
  gateway_identifier = aws_bedrockagentcore_gateway.tools.gateway_id
  description        = "Read-only Kubernetes tools (namespace demo)"

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.tool["read"].arn

        tool_schema {
          inline_payload {
            name        = "list_pods"
            description = "List pods in a namespace with their status and container images."
            input_schema {
              type = "object"
              property {
                name     = "namespace"
                type     = "string"
                required = true
              }
            }
          }
          inline_payload {
            name        = "get_deployment"
            description = "Get a Deployment: replicas, images, annotations and conditions."
            input_schema {
              type = "object"
              property {
                name     = "namespace"
                type     = "string"
                required = true
              }
              property {
                name     = "name"
                type     = "string"
                required = true
              }
            }
          }
          inline_payload {
            name        = "get_events"
            description = "List recent events in a namespace."
            input_schema {
              type = "object"
              property {
                name     = "namespace"
                type     = "string"
                required = true
              }
            }
          }
          inline_payload {
            name        = "get_pod_logs"
            description = "Get the last lines of a pod's logs."
            input_schema {
              type = "object"
              property {
                name     = "namespace"
                type     = "string"
                required = true
              }
              property {
                name     = "pod"
                type     = "string"
                required = true
              }
            }
          }
        }
      }
    }
  }
}

resource "aws_bedrockagentcore_gateway_target" "write" {
  name               = local.tools.write.target
  gateway_identifier = aws_bedrockagentcore_gateway.tools.gateway_id
  description        = "One write tool: change a container image in a Deployment"

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.tool["write"].arn

        tool_schema {
          inline_payload {
            name        = "update_deployment_image"
            description = "Set the image of one container in a Deployment."
            input_schema {
              type = "object"
              property {
                name     = "namespace"
                type     = "string"
                required = true
              }
              property {
                name     = "name"
                type     = "string"
                required = true
              }
              property {
                name     = "container"
                type     = "string"
                required = true
              }
              property {
                name     = "image"
                type     = "string"
                required = true
              }
            }
          }
        }
      }
    }
  }
}
