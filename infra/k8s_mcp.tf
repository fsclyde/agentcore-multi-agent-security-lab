# The upstream Kubernetes MCP server (containers/kubernetes-mcp-server) as a
# private AgentCore Gateway target.
#
#   Gateway --VPC Lattice--> internal ALB (TLS, ACM) --> NodePort 30080 --> MCP server pod
#
# The MCP server runs in EKS (deploy/kubernetes-mcp, step 3 of the lab) with
# its own ServiceAccount, read-only mode, a tool allowlist and RBAC limited to
# the demo namespace. Nothing is reachable from the internet: the ALB is
# internal and only accepts traffic from the Lattice resource gateway.

locals {
  mcp_node_port = 30080
  mcp_target    = "k8s-mcp"

  # Read tools HolmesGPT and the operator may call through the gateway.
  mcp_read_tools = ["events_list", "pods_list_in_namespace", "pods_get", "pods_log", "resources_get", "resources_list"]
}

# ------------------------------------------------------------------ TLS
resource "aws_acm_certificate" "mcp" {
  domain_name       = var.mcp_hostname
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "mcp_validation" {
  for_each = {
    for o in aws_acm_certificate.mcp.domain_validation_options : o.domain_name => o
  }

  zone_id = var.mcp_zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 300
}

resource "aws_acm_certificate_validation" "mcp" {
  certificate_arn         = aws_acm_certificate.mcp.arn
  validation_record_fqdns = [for r in aws_route53_record.mcp_validation : r.fqdn]
}

# ------------------------------------------------------------------ network
# The Lattice resource gateway that AgentCore creates in our subnets.
resource "aws_security_group" "mcp_lattice" {
  name        = "${local.name}-mcp-lattice"
  description = "AgentCore Gateway (VPC Lattice) to the MCP ALB"
  vpc_id      = module.vpc.vpc_id

  egress {
    description = "MCP ALB"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }
}

resource "aws_security_group" "mcp_alb" {
  name        = "${local.name}-mcp-alb"
  description = "Internal ALB in front of the Kubernetes MCP server"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "AgentCore Gateway through VPC Lattice only"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.mcp_lattice.id]
  }

  egress {
    description = "MCP server NodePort on the EKS nodes"
    from_port   = local.mcp_node_port
    to_port     = local.mcp_node_port
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }
}

# Managed node groups use the EKS cluster security group.
resource "aws_security_group_rule" "alb_to_mcp_nodeport" {
  type                     = "ingress"
  description              = "MCP ALB to the MCP server NodePort"
  from_port                = local.mcp_node_port
  to_port                  = local.mcp_node_port
  protocol                 = "tcp"
  security_group_id        = aws_eks_cluster.lab.vpc_config[0].cluster_security_group_id
  source_security_group_id = aws_security_group.mcp_alb.id
}

# ------------------------------------------------------------------ ALB
resource "aws_lb" "mcp" {
  name               = "${local.name}-mcp"
  internal           = true
  load_balancer_type = "application"
  subnets            = module.vpc.private_subnets
  security_groups    = [aws_security_group.mcp_alb.id]
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "mcp" {
  name        = "${local.name}-mcp"
  port        = local.mcp_node_port
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = module.vpc.vpc_id

  health_check {
    path    = "/healthz"
    matcher = "200"
  }
}

resource "aws_lb_listener" "mcp" {
  load_balancer_arn = aws_lb.mcp.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.mcp.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "not found"
      status_code  = "404"
    }
  }
}

# Only /mcp is forwarded; nothing else on the MCP server is reachable.
resource "aws_lb_listener_rule" "mcp" {
  listener_arn = aws_lb_listener.mcp.arn
  priority     = 10

  condition {
    path_pattern {
      values = ["/mcp", "/mcp/*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mcp.arn
  }
}

resource "aws_autoscaling_attachment" "mcp" {
  autoscaling_group_name = aws_eks_node_group.lab.resources[0].autoscaling_groups[0].name
  lb_target_group_arn    = aws_lb_target_group.mcp.arn
}

# ------------------------------------------------------------------ gateway target
# Created in step 6, once the MCP server runs in the cluster: the gateway
# lists the server's tools when the target is created.
resource "aws_bedrockagentcore_gateway_target" "k8s_mcp" {
  count = var.deploy_agents ? 1 : 0

  name               = local.mcp_target
  gateway_identifier = aws_bedrockagentcore_gateway.tools.gateway_id
  description        = "Upstream Kubernetes MCP server, read-only, namespace demo"

  target_configuration {
    mcp {
      mcp_server {
        endpoint = "https://${var.mcp_hostname}/mcp"
      }
    }
  }

  private_endpoint {
    managed_vpc_resource {
      vpc_identifier           = module.vpc.vpc_id
      subnet_ids               = module.vpc.private_subnets
      endpoint_ip_address_type = "IPV4"
      security_group_ids       = [aws_security_group.mcp_lattice.id]
      routing_domain           = aws_lb.mcp.dns_name # the certificate is for mcp_hostname; traffic goes to the ALB
    }
  }

  depends_on = [aws_lb_listener_rule.mcp]
}
