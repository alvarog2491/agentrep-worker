# Variables
variable "app_name" {
  description = "Application name"
  type        = string
}

variable "agent_runtime_version" {
  description = "Runtime version for PROD endpoint"
  type        = string
  default     = "1"
}

variable "mcp_runtime_arn" {
  description = "ARN of the agentrep-mcp AgentCore Runtime (e.g. arn:aws:bedrock-agentcore:<region>:<account>:runtime/<runtime-id>)"
  type        = string
}

variable "knowledge_base_id" {
  description = "Bedrock Knowledge Base ID to use as a retrieval tool (leave empty to disable)"
  type        = string
  default     = ""
}

data "aws_region" "current" { }

data "aws_caller_identity" "current" {}
