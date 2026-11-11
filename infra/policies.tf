# Cedar policies for the gateway. Default deny: a tool call is allowed only if
# a permit matches and no forbid matches.
#
# principal       = the agent's IAM role (the request is SigV4-signed)
# action          = <target>___<tool>
# resource        = this gateway
# context.input.* = the tool arguments. For the write tool, the REQUEST
#                   interceptor also adds _agent, _on_behalf_of and
#                   _on_behalf_of_role, so the decision covers the person too.
#
# Read tools come from the upstream Kubernetes MCP server, whose schemas we do
# not change: there the interceptor checks the person (valid token, SRE role,
# admin for the operator) before Cedar decides on the agent and the inputs.

resource "aws_bedrockagentcore_policy_engine" "lab" {
  name        = "${local.name}_sre_policies"
  description = "Which agent may call which tool, for whom, and with which inputs"
}

locals {
  gw = "AgentCore::Gateway::\"${aws_bedrockagentcore_gateway.tools.gateway_arn}\""
  # IAM principals are matched on the role, without the session name.
  holmes   = "AgentCore::IamEntity::\"arn:aws:sts::${local.account_id}:assumed-role/${aws_iam_role.agent["holmes"].name}\""
  operator = "AgentCore::IamEntity::\"arn:aws:sts::${local.account_id}:assumed-role/${aws_iam_role.agent["operator"].name}\""

  # Namespace-scoped reads on the MCP server.
  read_actions = join(", ", [
    for t in ["events_list", "pods_list_in_namespace", "pods_get", "pods_log"] :
    "AgentCore::Action::\"${local.mcp_target}___${t}\""
  ])
  # Generic reads, also limited to a few kinds (never Secret or ConfigMap).
  resource_actions = join(", ", [
    for t in ["resources_get", "resources_list"] : "AgentCore::Action::\"${local.mcp_target}___${t}\""
  ])
  in_demo       = "context.input has namespace && context.input.namespace == \"demo\""
  allowed_kinds = "context.input has kind && [\"Pod\", \"Deployment\", \"ReplicaSet\", \"Event\"].contains(context.input.kind)"
  write_action = "AgentCore::Action::\"${local.tools.write.target}___update_deployment_image\""

  # The agent name the interceptor wrote must match the signed IAM role, and a
  # person must be attached. Missing fields fail closed.
  acting_as_holmes   = "context.input has _agent && context.input._agent == \"holmes\" && context.input has _on_behalf_of_role"
  acting_as_operator = "context.input has _agent && context.input._agent == \"operator\" && context.input has _on_behalf_of_role"
}

# Reads on the MCP server: HolmesGPT and the operator, namespace demo only.
# Created with the MCP target (step 6): Cedar checks each policy against the
# target's tool schemas.
resource "aws_bedrockagentcore_policy" "mcp_read" {
  for_each = var.deploy_agents ? { holmes = local.holmes, operator = local.operator } : {}

  name             = "${each.key}_mcp_read_demo"
  policy_engine_id = aws_bedrockagentcore_policy_engine.lab.policy_engine_id
  description      = "${each.key} may read pods, logs and events in demo"

  definition {
    cedar {
      statement = <<-EOT
        permit(
          principal == ${each.value},
          action in [${local.read_actions}],
          resource == ${local.gw}
        )
        when { ${local.in_demo} };
      EOT
    }
  }

  depends_on = [aws_bedrockagentcore_gateway_target.k8s_mcp]
}

resource "aws_bedrockagentcore_policy" "mcp_resources" {
  for_each = var.deploy_agents ? { holmes = local.holmes, operator = local.operator } : {}

  name             = "${each.key}_mcp_resources_demo"
  policy_engine_id = aws_bedrockagentcore_policy_engine.lab.policy_engine_id
  description      = "${each.key} may read Pods, Deployments, ReplicaSets and Events in demo"

  definition {
    cedar {
      statement = <<-EOT
        permit(
          principal == ${each.value},
          action in [${local.resource_actions}],
          resource == ${local.gw}
        )
        when { ${local.in_demo} && ${local.allowed_kinds} };
      EOT
    }
  }

  depends_on = [aws_bedrockagentcore_gateway_target.k8s_mcp]
}

# Operator: one write, only for an sre-admin, narrowed by its inputs.
resource "aws_bedrockagentcore_policy" "operator_write" {
  name             = "operator_update_image_demo"
  policy_engine_id = aws_bedrockagentcore_policy_engine.lab.policy_engine_id
  description      = "The operator may change the image of demo-web for an sre-admin"

  definition {
    cedar {
      statement = <<-EOT
        permit(
          principal == ${local.operator},
          action == ${local.write_action},
          resource == ${local.gw}
        )
        when {
          ${local.acting_as_operator} &&
          context.input._on_behalf_of_role == "sre-admin" &&
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
