################################################################################
# ECR Repository
################################################################################
resource "aws_ecr_repository" "agentcore_terraform_runtime" {
  name                 = "bedrock-agentcore/${lower(var.app_name)}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}

data "aws_ecr_authorization_token" "token" {}

locals {
  src_files = fileset("../${path.root}/src", "**")

  build_files = [
    "../${path.root}/Dockerfile",
    "../${path.root}/pyproject.toml",
    "../${path.root}/poetry.lock",
  ]

  all_hashes = concat(
    [for f in local.src_files : filesha256("../${path.root}/src/${f}")],
    [for f in local.build_files : filesha256(f)],
  )

  combined_hash = sha256(join("", local.all_hashes))
}

resource "null_resource" "docker_image" {
  depends_on = [aws_ecr_repository.agentcore_terraform_runtime]

  triggers = {
    src_hash = local.combined_hash
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOF
      source ~/.bash_profile || source ~/.profile || true

      if ! command -v docker &> /dev/null; then
        echo "Docker is not installed or not in PATH. Please install Docker and try again."
        exit 1
      fi

      aws ecr get-login-password | docker login --username AWS --password-stdin ${data.aws_ecr_authorization_token.token.proxy_endpoint}

      docker build \
        -t ${aws_ecr_repository.agentcore_terraform_runtime.repository_url}:latest \
        -t ${aws_ecr_repository.agentcore_terraform_runtime.repository_url}:${local.combined_hash} \
        ../${path.root}

      docker push ${aws_ecr_repository.agentcore_terraform_runtime.repository_url}:latest
      docker push ${aws_ecr_repository.agentcore_terraform_runtime.repository_url}:${local.combined_hash}
    EOF
  }
}

################################################################################
# AgentCore Runtime IAM Role
################################################################################

data "aws_iam_policy_document" "bedrock_agentcore_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:bedrock-agentcore:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "agentcore_runtime_execution_role" {
  name        = "${var.app_name}-AgentCoreRuntimeRole"
  description = "Execution role for Bedrock AgentCore Runtime"

  assume_role_policy = data.aws_iam_policy_document.bedrock_agentcore_assume_role.json
}

# https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-permissions.html#runtime-permissions-execution
resource "aws_iam_role_policy" "agentcore_runtime_execution_role_policy" {
  role = aws_iam_role.agentcore_runtime_execution_role.id
  name = "${var.app_name}-AgentCoreRuntimeExecutionPolicy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRImageAccess"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = [
          "arn:aws:ecr:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:repository/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:DescribeLogStreams",
          "logs:CreateLogGroup",
        ]
        Resource = [
          "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
        ]
        Resource = [
          "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*",
        ]
      },
      {
        Sid    = "ECRTokenAccess"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets",
        ]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Resource = "*"
        Action   = "cloudwatch:PutMetricData"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "bedrock-agentcore"
          }
        }
      },
      {
        Sid    = "BedrockModelInvocation"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/*",
          "arn:aws:bedrock:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*",
        ]
      },
      {
        Sid    = "AgentCoreMemoryAccess"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:GetWorkloadAccessToken",
          "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
          "bedrock-agentcore:GetWorkloadAccessTokenForUserId",
        ]
        Resource = [
          "arn:aws:bedrock-agentcore:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:workload-identity-directory/default",
          "arn:aws:bedrock-agentcore:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:workload-identity-directory/default/workload-identity/worker_Agent*",
        ]
      },
      {
        Sid    = "MCPRuntimeInvocation"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:InvokeAgentRuntime",
        ]
        Resource = [
          "arn:aws:bedrock-agentcore:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:runtime/*",
        ]
      },
      {
        Sid    = "MemoryOperations"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:CreateEvent",
          "bedrock-agentcore:ListEvents",
          "bedrock-agentcore:GetEvent",
          "bedrock-agentcore:DeleteEvent",
        ]
        Resource = [
          "arn:aws:bedrock-agentcore:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:memory/*",
        ]
      },
      {
        Sid    = "KnowledgeBaseRetrieval"
        Effect = "Allow"
        Action = [
          "bedrock:Retrieve",
        ]
        Resource = [
          "arn:aws:bedrock:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:knowledge-base/*",
        ]
      },
    ]
  })
}

################################################################################
# AgentCore Memory (Short-Term)
################################################################################
resource "aws_bedrockagentcore_memory" "agentcore_memory" {
  name                  = "worker_Memory"
  description           = "Short-term memory: stores raw conversation turns for the current session"
  event_expiry_duration = 7
}

################################################################################
# AgentCore Runtime
################################################################################
resource "aws_bedrockagentcore_agent_runtime" "agentcore_runtime" {
  agent_runtime_name = "worker_Agent"
  role_arn           = aws_iam_role.agentcore_runtime_execution_role.arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = "${aws_ecr_repository.agentcore_terraform_runtime.repository_url}:${local.combined_hash}"
    }
  }

  depends_on = [null_resource.docker_image, aws_bedrockagentcore_memory.agentcore_memory]

  network_configuration {
    network_mode = "PUBLIC"
  }

  environment_variables = {
    AWS_REGION                  = data.aws_region.current.region
    BEDROCK_AGENTCORE_MEMORY_ID = aws_bedrockagentcore_memory.agentcore_memory.id
    MCP_RUNTIME_ARN             = var.mcp_runtime_arn
    KNOWLEDGE_BASE_ID           = var.knowledge_base_id
    AGENT_OBSERVABILITY_ENABLED = "true"
    OTEL_RESOURCE_ATTRIBUTES    = "service.name=worker_Agent"
  }
}

################################################################################
# AgentCore Runtime Endpoints
################################################################################


# PROD – pinned to a specific version; update agent_runtime_version in
# terraform.tfvars to promote a new version to production.
resource "aws_bedrockagentcore_agent_runtime_endpoint" "prod_endpoint" {
  name                  = "PROD"
  agent_runtime_id      = aws_bedrockagentcore_agent_runtime.agentcore_runtime.agent_runtime_id
  agent_runtime_version = var.agent_runtime_version
}
