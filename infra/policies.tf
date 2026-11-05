# Cedar policies for the gateway. Default deny: a tool call is allowed only if
# a permit matches and no forbid matches.
#
# principal       = the agent's IAM role (the request is SigV4-signed)
# action          = <target>___<tool>
# resource        = this gateway
# context.input.* = the tool arguments, plus the identity the REQUEST
#                   interceptor added: _agent, _on_behalf_of, _on_behalf_of_role
#
# So each decision covers both the agent and the person it acts for.

resource "aws_bedrockagentcore_policy_engine" "lab" {
  name        = "${local.name}_sre_policies"
  description = "Which agent may call which tool, for whom, and with which inputs"
}

locals {
  gw = "AgentCore::Gateway::\"${aws_bedrockagentcore_gateway.tools.gateway_arn}\""
  # IAM principals are matched on the role, without the session name.
  holmes   = "AgentCore::IamEntity::\"arn:aws:sts::${local.account_id}:assumed-role/${aws_iam_role.agent["holmes"].name}\""
  operator = "AgentCore::IamEntity::\"arn:aws:sts::${local.account_id}:assumed-role/${aws_iam_role.agent["operator"].name}\""

  read_actions = join(", ", [
    for t in local.tool_defs.read : "AgentCore::Action::\"${local.tools.read.target}___${t.name}\""
  ])
  write_action = "AgentCore::Action::\"${local.tools.write.target}___update_deployment_image\""

  # The agent name the interceptor wrote must match the signed IAM role, and a
  # person must be attached. Missing fields fail closed.
  acting_as_holmes   = "context.input has _agent && context.input._agent == \"holmes\" && context.input has _on_behalf_of_role"
  acting_as_operator = "context.input has _agent && context.input._agent == \"operator\" && context.input has _on_behalf_of_role"
}

# HolmesGPT: read tools, namespace demo only, for a viewer or an admin.
resource "aws_bedrockagentcore_policy" "holmes_read" {
  name             = "holmes_read_demo"
  policy_engine_id = aws_bedrockagentcore_policy_engine.lab.policy_engine_id
  description      = "HolmesGPT may read the demo namespace for an SRE"

  definition {
    cedar {
      statement = <<-EOT
        permit(
          principal == ${local.holmes},
          action in [${local.read_actions}],
          resource == ${local.gw}
        )
        when {
          ${local.acting_as_holmes} &&
          context.input.namespace == "demo"
        };
      EOT
    }
  }
}

# Operator: the same reads, so it can check the Deployment before changing it.
resource "aws_bedrockagentcore_policy" "operator_read" {
  name             = "operator_read_demo"
  policy_engine_id = aws_bedrockagentcore_policy_engine.lab.policy_engine_id
  description      = "The operator may read the demo namespace for an admin"

  definition {
    cedar {
      statement = <<-EOT
        permit(
          principal == ${local.operator},
          action in [${local.read_actions}],
          resource == ${local.gw}
        )
        when {
          ${local.acting_as_operator} &&
          context.input._on_behalf_of_role == "sre-admin" &&
          context.input.namespace == "demo"
        };
      EOT
    }
  }
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
