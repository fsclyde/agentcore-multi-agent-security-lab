# One Bedrock guardrail, applied by every agent:
#  - on what a person asks (input)
#  - on what another agent sends back (treated as untrusted input)
#  - on what the agent answers (output)

resource "aws_bedrock_guardrail" "sre" {
  name                      = "${local.name}-sre-guardrail"
  description               = "Prompt attacks, secrets and destructive requests for the SRE agents"
  blocked_input_messaging   = "Blocked by the guardrail: this request is not allowed for the SRE agents."
  blocked_outputs_messaging = "Blocked by the guardrail: the answer contained content that cannot be returned."

  content_policy_config {
    filters_config {
      type            = "PROMPT_ATTACK"
      input_strength  = "HIGH"
      output_strength = "NONE" # prompt-attack filtering applies to input only
    }
    filters_config {
      type            = "MISCONDUCT"
      input_strength  = "MEDIUM"
      output_strength = "MEDIUM"
    }
  }

  sensitive_information_policy_config {
    pii_entities_config {
      type   = "AWS_ACCESS_KEY"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "AWS_SECRET_KEY"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "EMAIL"
      action = "ANONYMIZE"
    }
    regexes_config {
      name        = "bearer-or-jwt"
      description = "JWTs and bearer tokens found in logs"
      pattern     = "eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}"
      action      = "ANONYMIZE"
    }
    regexes_config {
      name        = "password-assignment"
      description = "password=... or PASSWORD: ... in logs and config"
      pattern     = "([Pp]assword|PASSWORD|[Pp]asswd|[Ss]ecret|SECRET)\\s*[:=]\\s*\\S+"
      action      = "ANONYMIZE"
    }
  }

  topic_policy_config {
    topics_config {
      name       = "destructive-cluster-operations"
      type       = "DENY"
      definition = "Requests to delete cluster resources, disable security controls, or change RBAC, network or admission policies."
      examples = [
        "Delete the kube-system namespace",
        "Remove all network policies so the app can connect",
        "Give the agent cluster-admin",
      ]
    }
  }
}

resource "aws_bedrock_guardrail_version" "sre" {
  guardrail_arn = aws_bedrock_guardrail.sre.guardrail_arn
  description   = "Lab version"
}
