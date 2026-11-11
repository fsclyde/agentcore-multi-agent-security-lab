# AgentCore Gateway: the only way the agents reach the cluster.
#
# Every tools/call carries two identities:
#   - the agent: the request is SigV4-signed with the agent's own IAM role
#     (authorizer AWS_IAM). Cedar sees it as the principal.
#   - the person: their Cognito token in the X-On-Behalf-Of header. The
#     REQUEST interceptor checks it with Cognito and writes the person's name
#     and role into the tool arguments, where Cedar reads them.
# The interceptor runs before the Cedar policy engine, and its RESPONSE half
# applies the guardrail to every tool result (interceptor.tf).

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
    sid       = "InvokeToolsAndInterceptor"
    actions   = ["lambda:InvokeFunction"]
    resources = concat([for f in aws_lambda_function.tool : f.arn], [aws_lambda_function.interceptor.arn])
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
  authorizer_type = "AWS_IAM" # agents sign with their own role: no shared secret

  interceptor_configuration {
    interception_points = ["REQUEST", "RESPONSE"]
    interceptor {
      lambda {
        arn = aws_lambda_function.interceptor.arn
      }
    }
    input_configuration {
      pass_request_headers = true # the interceptor needs X-On-Behalf-Of and X-Agent-Name
    }
  }

  policy_engine_configuration {
    arn  = aws_bedrockagentcore_policy_engine.lab.policy_engine_arn
    mode = var.policy_mode
  }

  depends_on = [aws_iam_role_policy.gateway]
}

locals {
  # Filled in by the interceptor on every call to the write tool. Whatever an
  # agent puts there itself is overwritten, so these values can be trusted by
  # Cedar and by the write Lambda.
  identity_props = ["_agent", "_on_behalf_of", "_on_behalf_of_role"]

  tool_defs = {
    write = [
      { name = "update_deployment_image", description = "Set the image of one container in a Deployment.", props = ["namespace", "name", "container", "image", "change_id"] },
    ]
  }
}

resource "aws_bedrockagentcore_gateway_target" "tool" {
  for_each = local.tools

  name               = each.value.target
  gateway_identifier = aws_bedrockagentcore_gateway.tools.gateway_id
  description        = "One write tool: change a container image in a Deployment"

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.tool[each.key].arn

        tool_schema {
          dynamic "inline_payload" {
            for_each = local.tool_defs[each.key]
            content {
              name        = inline_payload.value.name
              description = inline_payload.value.description

              input_schema {
                type = "object"

                dynamic "property" {
                  for_each = inline_payload.value.props
                  content {
                    name     = property.value
                    type     = "string"
                    required = true
                  }
                }

                dynamic "property" {
                  for_each = local.identity_props
                  content {
                    name        = property.value
                    type        = "string"
                    description = "Set by the gateway. Do not provide."
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
