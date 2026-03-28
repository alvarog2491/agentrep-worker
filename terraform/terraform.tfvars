# Application Configuration
app_name = "worker"

# Runtime Version for PROD endpoint
# Update this value when you want to promote a new version to production
# DEV endpoint always uses the latest version automatically
agent_runtime_version = "1"

# MCP server connection
# Fill in with the invocation URL from your agentrep-mcp deployment
mcp_runtime_url = "https://bedrock-agentcore.us-east-1.amazonaws.com/runtimes/arn%3Aaws%3Abedrock-agentcore%3Aus-east-1%3A026898548947%3Aruntime%2Fmcp_serverless_runtime-DeOeqTBNUu/invocations"

# Bedrock Knowledge Base ID (leave empty to run without knowledge base)
knowledge_base_id = "NKXBV35WPS"
