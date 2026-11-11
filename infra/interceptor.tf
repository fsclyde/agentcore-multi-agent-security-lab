# Gateway interceptor: one Lambda, two interception points.
#
# REQUEST  (before Cedar): validates the person's Cognito token locally
#          (signature, issuer, expiry, client), refuses writes for anyone who
#          is not sre-admin, and for the write tool also checks the live
#          session and a four-eyes approval (SSM, single use). It writes
#          _agent, _on_behalf_of and _on_behalf_of_role into write calls.
# RESPONSE (before the agent sees it): runs every tool result through the
#          Bedrock guardrail. The agent's own code cannot skip this.

data "archive_file" "interceptor" {
  type        = "zip"
  source_file = "${path.module}/lambda/interceptor.py"
  output_path = "${path.module}/build/interceptor.zip"
}

resource "aws_iam_role" "interceptor" {
  name               = "${local.name}-interceptor"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "interceptor_logs" {
  role       = aws_iam_role.interceptor.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "interceptor" {
  name = "guardrail-and-approvals"
  role = aws_iam_role.interceptor.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["bedrock:ApplyGuardrail"]
        Resource = aws_bedrock_guardrail.sre.guardrail_arn
      },
      {
        # Read an approval and delete it when used (single use).
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:DeleteParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter${local.approval_prefix}*"
      },
      {
        # Approvals are SecureString parameters with the AWS managed key.
        Effect    = "Allow"
        Action    = ["kms:Decrypt"]
        Resource  = "*"
        Condition = { StringEquals = { "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com" } }
      },
    ]
  })
}

locals {
  approval_prefix = "/${local.name}/approvals/"
}

resource "aws_lambda_function" "interceptor" {
  function_name    = "${local.name}-gateway-interceptor"
  role             = aws_iam_role.interceptor.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "interceptor.handler"
  filename         = data.archive_file.interceptor.output_path
  source_code_hash = data.archive_file.interceptor.output_base64sha256
  timeout          = 15

  environment {
    variables = {
      USER_POOL_ID      = aws_cognito_user_pool.lab.id
      USER_CLIENT_ID    = aws_cognito_user_pool_client.user.id
      GUARDRAIL_ID      = aws_bedrock_guardrail.sre.guardrail_id
      GUARDRAIL_VERSION = aws_bedrock_guardrail_version.sre.version
      WRITE_TARGET      = local.tools.write.target
      APPROVAL_PREFIX   = local.approval_prefix
    }
  }
}

resource "aws_cloudwatch_log_group" "interceptor" {
  name              = "/aws/lambda/${aws_lambda_function.interceptor.function_name}"
  retention_in_days = 7
}

# Saved Logs Insights queries over the interceptor's decision log. Saved
# queries cost nothing; you only pay for the data a query scans when you run
# it. Metric filters and alarms add monthly charges: see docs/known-gaps.md.
resource "aws_cloudwatch_query_definition" "interceptor" {
  for_each = {
    denied = "fields @timestamp, reason, tool, agent, on_behalf_of | filter decision = \"DENY\" | sort @timestamp desc"
    writes = "fields @timestamp, tool, agent, on_behalf_of, change_id, approved_by | filter decision = \"PASS\" and write = 1 | sort @timestamp desc"
    guardrail = "fields @timestamp, tool, blocked | filter guardrail = \"INTERVENED\" | sort @timestamp desc"
    by_person = "filter ispresent(on_behalf_of) | stats count(*) as calls by on_behalf_of, agent, decision"
  }

  name            = "${local.name}/gateway/${each.key}"
  log_group_names = [aws_cloudwatch_log_group.interceptor.name]
  query_string    = each.value
}
