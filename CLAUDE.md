# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Install all dependencies (including dev)
poetry install

# Run tests
poetry run pytest

# Run a single test file
poetry run pytest tests/test_main.py

# Run the agent locally (requires AWS credentials and env vars)
poetry run python -m src.main

# Add a dependency
poetry add <package>

# Add a dev dependency
poetry add --group dev <package>
```

## Terraform (Deploy)

All infrastructure commands must be run from the `terraform/` directory.

```bash
cd terraform
terraform init
terraform plan
terraform apply     # builds Docker image, pushes to ECR, deploys AgentCore Runtime
terraform destroy
```

Set `mcp_runtime_url` in [terraform/terraform.tfvars](terraform/terraform.tfvars) to the invocation URL of the deployed `agentrep-mcp` runtime before first deploy.

Terraform detects code changes via a SHA256 hash of all files under `src/`. Running `terraform apply` after any `src/` change automatically rebuilds and redeploys the container.

## Architecture

This is a **Strands agent** deployed as an **Amazon Bedrock AgentCore Runtime** container. The agent handles customer experience / lead collection conversations.

**Request flow:**
1. `BedrockAgentCoreApp` receives an invocation with `{"prompt": "..."}` and a `context` carrying `session_id`
2. `ShortTermMemoryHook` fires on `AgentInitializedEvent` — fetches the last 10 conversation turns from AgentCore Memory and appends them to the system prompt
3. `get_mcp_client()` opens a streamable-HTTP MCP connection to the `agentrep-mcp` runtime (authenticated via SigV4 using the execution role)
4. Tools are discovered dynamically via `client.list_tools_sync()` — no hardcoded tool list
5. `Agent.stream_async()` streams response chunks back to the caller; each chunk with a `"data"` string key is yielded
6. `ShortTermMemoryHook` fires on `MessageAddedEvent` — saves each new message to AgentCore Memory

**Key files:**
- [src/main.py](src/main.py) — entrypoint, `ShortTermMemoryHook`, `invoke` handler
- [src/mcp_client/client.py](src/mcp_client/client.py) — SigV4-authenticated MCP client for the AgentCore Gateway
- [src/model/load.py](src/model/load.py) — loads `global.meta.llama3-8b-instruct-v1:0` via `BedrockModel`
- [terraform/bedrock_agentcore.tf](terraform/bedrock_agentcore.tf) — ECR, IAM role, Memory resource, Runtime, DEV/PROD endpoints

**Memory:** `worker_Memory` (AgentCore STM) stores raw conversation turns keyed by `(actor_id="user", session_id)`. Events expire after 7 days. No extraction strategies — memory does not persist across sessions. The memory ID is passed to the container via `BEDROCK_AGENTCORE_MEMORY_ID`; if unset, the hook is skipped and the agent runs memoryless.

**MCP tools:** Defined in the separate `agentrep-mcp` project. Adding a tool there requires no changes here — tools are discovered at invocation time.

## Environment Variables

| Variable | Description |
|---|---|
| `AWS_REGION` | AWS region (default: `us-east-1`) |
| `BEDROCK_AGENTCORE_MEMORY_ID` | AgentCore Memory resource ID (injected by Terraform) |
| `MCP_SERVER_URL` | Invocation URL of the `agentrep-mcp` AgentCore Runtime (injected by Terraform) |

## README Hook

A `PostToolUse` hook in [.claude/settings.json](.claude/settings.json) triggers after every file write and prompts an agent to check whether [README.md](README.md) needs updating. When you edit source files, review the README to keep it in sync — especially the Project Structure, Tools table, Environment Variables, and AgentCore Best Practices sections.
