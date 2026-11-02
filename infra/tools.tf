# Two tool Lambdas behind the gateway. Same code, different IAM role and
# different Kubernetes group, so the read tools cannot write even if a policy
# above them is wrong.

locals {
  tools = {
    read = {
      target    = "k8s-read"
      k8s_group = "agentcore-k8s-read"
      mode      = "READ"
    }
    write = {
      target    = "k8s-write"
      k8s_group = "agentcore-k8s-write"
      mode      = "WRITE"
    }
  }
}

data "archive_file" "tools" {
  type        = "zip"
  source_file = "${path.module}/lambda/k8s_tools.py"
  output_path = "${path.module}/build/k8s_tools.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "tool" {
  for_each           = local.tools
  name               = "${local.name}-tool-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "tool_vpc" {
  for_each   = local.tools
  role       = aws_iam_role.tool[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_security_group" "tools" {
  name        = "${local.name}-tools"
  description = "Tool Lambdas: egress to the EKS API only"
  vpc_id      = module.vpc.vpc_id

  egress {
    description = "EKS API inside the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }
}

resource "aws_lambda_function" "tool" {
  for_each = local.tools

  function_name    = "${local.name}-${each.value.target}"
  role             = aws_iam_role.tool[each.key].arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "k8s_tools.handler"
  filename         = data.archive_file.tools.output_path
  source_code_hash = data.archive_file.tools.output_base64sha256
  timeout          = 30

  vpc_config {
    subnet_ids         = module.vpc.private_subnets
    security_group_ids = [aws_security_group.tools.id]
  }

  environment {
    variables = {
      MODE         = each.value.mode
      CLUSTER_NAME = aws_eks_cluster.lab.name
      API_ENDPOINT = aws_eks_cluster.lab.endpoint
      CLUSTER_CA   = aws_eks_cluster.lab.certificate_authority[0].data
    }
  }
}

resource "aws_cloudwatch_log_group" "tool" {
  for_each          = local.tools
  name              = "/aws/lambda/${aws_lambda_function.tool[each.key].function_name}"
  retention_in_days = 7
}
