terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.19"
    }
  }

  required_version = ">= 1.2"
}

output "agentcore_runtime_id" {
  description = "AgentCore Runtime ID"
  value       = aws_bedrockagentcore_agent_runtime.agentcore_runtime.agent_runtime_id
}

output "agentcore_runtime_version" {
  description = "Latest deployed runtime version — set agent_runtime_version in terraform.tfvars to this value to promote to PROD"
  value       = aws_bedrockagentcore_agent_runtime.agentcore_runtime.agent_runtime_version
}

output "ecr_repository_url" {
  description = "ECR Repository URL"
  value       = aws_ecr_repository.agentcore_terraform_runtime.repository_url
}
