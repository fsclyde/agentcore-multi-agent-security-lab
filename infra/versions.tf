terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.50" # 6.50 adds AgentCore policies and the gateway policy_engine_configuration
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  # State: copy backend.tf.example to backend.tf to keep it in an encrypted,
  # versioned S3 bucket (scripts/bootstrap-state.sh creates it). The lab holds
  # no secrets in state: agents use IAM roles and user passwords stay local.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "agentcore-multi-agent-security-lab"
      ManagedBy = "terraform"
      Owner     = var.owner
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name       = "acsl" # agentcore security lab
  account_id = data.aws_caller_identity.current.account_id
  azs        = slice(data.aws_availability_zones.available.names, 0, 2)
}
