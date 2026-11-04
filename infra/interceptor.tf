# Gateway interceptor: one Lambda, two interception points.
#
# REQUEST  (before Cedar): checks the person's Cognito token with Cognito,
#          refuses calls without a valid one, refuses writes for anyone who is
#          not sre-admin, and writes _agent, _on_behalf_of and
#          _on_behalf_of_role into the tool arguments for Cedar and the tools.
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
  name = "guardrail"
  role = aws_iam_role.interceptor.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["bedrock:ApplyGuardrail"]
      Resource = aws_bedrock_guardrail.sre.guardrail_arn
    }]
  })
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
    }
  }
}

resource "aws_cloudwatch_log_group" "interceptor" {
  name              = "/aws/lambda/${aws_lambda_function.interceptor.function_name}"
  retention_in_days = 7
}
