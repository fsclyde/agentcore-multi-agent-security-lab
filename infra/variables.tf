variable "aws_region" {
  description = "Region with Amazon Bedrock AgentCore (Runtime, Gateway and Policy) and the model below."
  type        = string
  default     = "eu-west-1"
}

variable "owner" {
  description = "Value of the Owner tag on every resource."
  type        = string
  default     = "lab"
}

variable "admin_cidr" {
  description = "Your public IP in CIDR form (x.x.x.x/32). Only this address can reach the EKS public API endpoint."
  type        = string
}

variable "model_id" {
  description = "Bedrock model or inference profile used by the three agents. Check that it is enabled in your account and region."
  type        = string
  default     = "eu.anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "policy_mode" {
  description = "Gateway policy engine mode. Start with LOG_ONLY, switch to ENFORCE in step 7 of the lab."
  type        = string
  default     = "LOG_ONLY"

  validation {
    condition     = contains(["LOG_ONLY", "ENFORCE"], var.policy_mode)
    error_message = "policy_mode must be LOG_ONLY or ENFORCE."
  }
}

variable "deploy_agents" {
  description = "Create the three AgentCore runtimes. Leave false until the images are pushed to ECR (step 5)."
  type        = bool
  default     = false
}

variable "image_tag" {
  description = "Tag of the agent images pushed by scripts/build-push.sh."
  type        = string
  default     = "v1"
}

variable "block_operator" {
  description = "Incident switch (step 11): forbid every tool call by the operator agent."
  type        = bool
  default     = false
}

variable "allow_test_assume" {
  description = "Let the identity running Terraform assume the agent roles, so scripts/checks.py can test the gateway as each agent. Set to false after testing."
  type        = bool
  default     = true
}

variable "mcp_hostname" {
  description = "Name on the TLS certificate of the Kubernetes MCP server, in a Route 53 zone you own (for example k8s-mcp.lab.example.com). It does not need to resolve publicly: the gateway reaches the internal ALB through VPC Lattice."
  type        = string
}

variable "mcp_zone_id" {
  description = "Route 53 public hosted zone for mcp_hostname, used only for the ACM DNS validation record."
  type        = string
}
