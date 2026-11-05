# The agents run inside the VPC and reach AWS only through VPC endpoints.
# Their security group allows HTTPS to the VPC and nothing else, so agent
# traffic never leaves the AWS network, even though the subnets have a NAT
# gateway for the EKS node.

resource "aws_security_group" "agents" {
  name        = "${local.name}-agents"
  description = "AgentCore runtimes: HTTPS to VPC endpoints only"
  vpc_id      = module.vpc.vpc_id

  egress {
    description = "VPC endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }
}

resource "aws_security_group" "endpoints" {
  name        = "${local.name}-endpoints"
  description = "Interface endpoints: HTTPS from the agents only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Agents"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.agents.id]
  }
}

locals {
  interface_endpoints = {
    bedrock_runtime   = "bedrock-runtime"               # model calls and ApplyGuardrail
    agentcore         = "bedrock-agentcore"             # A2A calls from triage to the workers
    agentcore_gateway = "bedrock-agentcore.gateway"     # tool calls from the workers
    ssm               = "ssm"                           # triage reads the worker ARNs
    logs              = "logs"                          # agent logs
    xray              = "xray"                          # traces
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${local.name}-${each.key}"
  }
}
