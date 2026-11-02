# Cedar policies for the gateway. Default deny: a tool call is allowed only if
# a permit matches and no forbid matches.
#
# Principal = the agent's Cognito client (sub of a client-credentials token).
# Action    = <target>___<tool>
# Resource  = this gateway

resource "aws_bedrockagentcore_policy_engine" "lab" {
  name        = "${local.name}_sre_policies"
  description = "Which agent may call which Kubernetes tool, and with which inputs"
}

locals {
  gw       = "AgentCore::Gateway::\"${aws_bedrockagentcore_gateway.tools.gateway_arn}\""
  holmes   = "AgentCore::OAuthUser::\"${aws_cognito_user_pool_client.agent["holmes"].id}\""
  operator = "AgentCore::OAuthUser::\"${aws_cognito_user_pool_client.agent["operator"].id}\""

  read_actions = join(", ", [
    for t in ["list_pods", "get_deployment", "get_events", "get_pod_logs"] :
    "AgentCore::Action::\"${local.tools.read.target}___${t}\""
  ])
  write_action = "AgentCore::Action::\"${local.tools.write.target}___update_deployment_image\""
}

# HolmesGPT: read tools, namespace demo only.
resource "aws_bedrockagentcore_policy" "holmes_read" {
  name             = "holmes_read_demo"
  policy_engine_id = aws_bedrockagentcore_policy_engine.lab.policy_engine_id
  description      = "HolmesGPT may read the demo namespace"

  definition {
    cedar {
      statement = <<-EOT
        permit(
          principal == ${local.holmes},
          action in [${local.read_actions}],
          resource == ${local.gw}
        )
        when { context.input.namespace == "demo" };
      EOT
    }
  }
}

# Operator: the same reads, so it can check the Deployment before changing it.
resource "aws_bedrockagentcore_policy" "operator_read" {
  name             = "operator_read_demo"
  policy_engine_id = aws_bedrockagentcore_policy_engine.lab.policy_engine_id
  description      = "The operator may read the demo namespace"

  definition {
    cedar {
      statement = <<-EOT
        permit(
          principal == ${local.operator},
          action in [${local.read_actions}],
          resource == ${local.gw}
        )
        when { context.input.namespace == "demo" };
      EOT
    }
  }
}

# Operator: one write, narrowed by its inputs.
resource "aws_bedrockagentcore_policy" "operator_write" {
  name             = "operator_update_image_demo"
  policy_engine_id = aws_bedrockagentcore_policy_engine.lab.policy_engine_id
  description      = "The operator may change the image of demo-web to an nginx-unprivileged image"

  definition {
    cedar {
      statement = <<-EOT
        permit(
          principal == ${local.operator},
          action == ${local.write_action},
          resource == ${local.gw}
        )
        when {
          context.input.namespace == "demo" &&
          context.input.name == "demo-web" &&
          context.input.image like "nginxinc/nginx-unprivileged:*"
        };
      EOT
    }
  }
}

# HolmesGPT never writes. Explicit, so no future permit can open it by mistake.
resource "aws_bedrockagentcore_policy" "holmes_no_write" {
  name             = "holmes_never_writes"
  policy_engine_id = aws_bedrockagentcore_policy_engine.lab.policy_engine_id
  description      = "The investigator can never call the write tool"

  definition {
    cedar {
      statement = <<-EOT
        forbid(
          principal == ${local.holmes},
          action == ${local.write_action},
          resource == ${local.gw}
        );
      EOT
    }
  }
}

# Incident switch: one forbid blocks every tool for the operator, at once,
# without touching the agent. terraform apply -var block_operator=true
resource "aws_bedrockagentcore_policy" "block_operator" {
  count            = var.block_operator ? 1 : 0
  name             = "incident_block_operator"
  policy_engine_id = aws_bedrockagentcore_policy_engine.lab.policy_engine_id
  description      = "Containment: the operator agent may not call any tool"

  definition {
    cedar {
      statement = <<-EOT
        forbid(
          principal == ${local.operator},
          action,
          resource == ${local.gw}
        );
      EOT
    }
  }
}
