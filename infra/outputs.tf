output "region" {
  value = var.aws_region
}

output "cluster_name" {
  value = aws_eks_cluster.lab.name
}

output "user_pool_id" {
  value = aws_cognito_user_pool.lab.id
}

output "user_client_id" {
  value = aws_cognito_user_pool_client.user.id
}

output "agent_client_ids" {
  value = { for k, c in aws_cognito_user_pool_client.agent : k => c.id }
}

output "token_endpoint" {
  value = local.token_endpoint
}

output "gateway_url" {
  value = aws_bedrockagentcore_gateway.tools.gateway_url
}

output "gateway_id" {
  value = aws_bedrockagentcore_gateway.tools.gateway_id
}

output "policy_engine_id" {
  value = aws_bedrockagentcore_policy_engine.lab.policy_engine_id
}

output "guardrail" {
  value = {
    id      = aws_bedrock_guardrail.sre.guardrail_id
    version = aws_bedrock_guardrail_version.sre.version
  }
}

output "ecr_repositories" {
  value = { for k, r in aws_ecr_repository.agent : k => r.repository_url }
}

output "runtime_arns" {
  value = { for k, r in aws_bedrockagentcore_agent_runtime.agent : k => r.agent_runtime_arn }
}
