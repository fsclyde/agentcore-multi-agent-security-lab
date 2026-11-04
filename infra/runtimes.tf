# Three agents on AgentCore Runtime, each with its own execution role, inside
# the VPC (network.tf).
#
#   triage    (HTTP)  the entry point. Accepts a person's Cognito token.
#   holmes    (A2A)   investigates. Accepts the forwarded token of an
#                     sre-viewer or sre-admin.
#   operator  (A2A)   repairs. Accepts the forwarded token of an sre-admin only.
#
# The person's group is checked by AgentCore before the request reaches the
# container. Workers then call the gateway signed with their own role and with
# the person's token attached, so the gateway sees both.

resource "aws_ecr_repository" "agent" {
  for_each             = toset(["triage", "holmes", "operator"])
  name                 = "${local.name}/${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

locals {
  agents = {
    triage   = { protocol = "HTTP", groups = ["sre-viewer", "sre-admin"], tools = false }
    holmes   = { protocol = "A2A", groups = ["sre-viewer", "sre-admin"], tools = true }
    operator = { protocol = "A2A", groups = ["sre-admin"], tools = true }
  }

  common_env = {
    AWS_REGION        = var.aws_region
    MODEL_ID          = var.model_id
    GUARDRAIL_ID      = aws_bedrock_guardrail.sre.guardrail_id
    GUARDRAIL_VERSION = aws_bedrock_guardrail_version.sre.version
  }
}

# The role (not the temporary session) you run Terraform with.
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

data "aws_iam_policy_document" "agent_assume" {
  source_policy_documents = [data.aws_iam_policy_document.agentcore_assume.json]

  # Lets scripts/checks.py act as each agent to test the gateway policies.
  # Set allow_test_assume = false once you have finished testing.
  dynamic "statement" {
    for_each = var.allow_test_assume ? [1] : []
    content {
      sid     = "LabTester"
      actions = ["sts:AssumeRole"]
      principals {
        type        = "AWS"
        identifiers = [data.aws_iam_session_context.current.issuer_arn]
      }
    }
  }
}

resource "aws_iam_role" "agent" {
  for_each           = local.agents
  name               = "${local.name}-agent-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.agent_assume.json
}

data "aws_iam_policy_document" "agent" {
  for_each = local.agents

  statement {
    sid       = "PullOwnImage"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = [aws_ecr_repository.agent[each.key].arn]
  }

  statement {
    sid       = "EcrToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "Logs"
    actions = [
      "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
      "logs:DescribeLogStreams", "logs:DescribeLogGroups",
    ]
    resources = ["arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/bedrock-agentcore/*"]
  }

  statement {
    sid       = "Traces"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "cloudwatch:PutMetricData"]
    resources = ["*"]
  }

  statement {
    sid       = "InvokeModel"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = ["arn:aws:bedrock:*::foundation-model/*", "arn:aws:bedrock:*:${local.account_id}:inference-profile/*"]
  }

  statement {
    sid       = "UseGuardrail"
    actions   = ["bedrock:ApplyGuardrail"]
    resources = [aws_bedrock_guardrail.sre.guardrail_arn]
  }

  dynamic "statement" {
    for_each = each.value.tools ? [1] : []
    content {
      sid       = "CallToolGateway"
      actions   = ["bedrock-agentcore:InvokeGateway"]
      resources = [aws_bedrockagentcore_gateway.tools.gateway_arn]
    }
  }
}

resource "aws_iam_role_policy" "agent" {
  for_each = local.agents
  name     = "agent"
  role     = aws_iam_role.agent[each.key].id
  policy   = data.aws_iam_policy_document.agent[each.key].json
}

resource "aws_bedrockagentcore_agent_runtime" "agent" {
  for_each = var.deploy_agents ? local.agents : {}

  agent_runtime_name = "${local.name}_${each.key}"
  description        = "SRE lab agent: ${each.key}"
  role_arn           = aws_iam_role.agent[each.key].arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = "${aws_ecr_repository.agent[each.key].repository_url}:${var.image_tag}"
    }
  }

  network_configuration {
    network_mode = "VPC"
    network_mode_config {
      subnets         = module.vpc.private_subnets
      security_groups = [aws_security_group.agents.id]
    }
  }

  protocol_configuration {
    server_protocol = each.value.protocol
  }

  # Only people's tokens from the CLI client, and only from the right groups.
  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url   = local.oidc_discovery_url
      allowed_clients = [aws_cognito_user_pool_client.user.id]

      custom_claim {
        inbound_token_claim_name       = "cognito:groups"
        inbound_token_claim_value_type = "STRING_ARRAY"
        authorizing_claim_match_value {
          claim_match_operator = "CONTAINS_ANY"
          claim_match_value {
            match_value_string_list = each.value.groups
          }
        }
      }
    }
  }

  # Each agent reads the person's token to forward it, to a worker or to the gateway.
  request_header_configuration {
    request_header_allowlist = ["Authorization"]
  }

  environment_variables = merge(local.common_env, {
    AGENT_NAME  = each.key
    GATEWAY_URL = each.value.tools ? aws_bedrockagentcore_gateway.tools.gateway_url : ""
  })

  depends_on = [aws_iam_role_policy.agent, aws_vpc_endpoint.interface]
}

# The triage agent learns where the workers are after they exist, through an
# SSM parameter read at the first request. That avoids a cycle between runtimes.
resource "aws_ssm_parameter" "worker_arns" {
  count = var.deploy_agents ? 1 : 0
  name  = "/${local.name}/worker-arns"
  type  = "String"
  value = jsonencode({
    holmes   = aws_bedrockagentcore_agent_runtime.agent["holmes"].agent_runtime_arn
    operator = aws_bedrockagentcore_agent_runtime.agent["operator"].agent_runtime_arn
  })
}

resource "aws_iam_role_policy" "triage_read_workers" {
  name = "read-worker-arns"
  role = aws_iam_role.agent["triage"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter/${local.name}/worker-arns"
    }]
  })
}
