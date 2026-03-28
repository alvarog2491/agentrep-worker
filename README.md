# agentrep-worker — Customer Experience Agent on Amazon Bedrock AgentCore

A conversational AI agent built for **customer experience** use cases. It connects to the `agentrep-mcp` MCP server to access business automation tools, uses **AgentCore Memory** for short-term conversation context within a session, and will integrate an **Amazon Bedrock Knowledge Base** to query up-to-date company data. Designed to run on **Amazon Bedrock AgentCore Runtime**.

## Contents

- [Architecture](#architecture)
- [MCP Server & Available Tools](#mcp-server--available-tools)
- [Memory](#memory)
- [Knowledge Base](#knowledge-base)
- [Project Structure](#project-structure)
- [Prerequisites](#prerequisites)
- [Dependency Management (Poetry)](#dependency-management-poetry)
- [Deploying to Amazon Bedrock AgentCore Runtime](#deploying-to-amazon-bedrock-agentcore-runtime)
- [Environment Variables](#environment-variables)
- [Observability](#observability)
- [AgentCore Best Practices Applied](#agentcore-best-practices-applied)
- [Resources](#resources)

## Architecture

The worker agent receives a customer prompt, retrieves relevant memory for the user, connects directly to the `agentrep-mcp` AgentCore Runtime to discover and invoke MCP tools, and streams the response back to the caller.

```
Customer Request
      │
      ▼
AgentCore Runtime (worker_Agent)
      │
      ├─── AgentCore Memory (STM) ──► Raw conversation turns for the current session
      │
      ├─── Bedrock Knowledge Base (planned) ──► Current company data, products, policies
      │
      └─── agentrep-mcp AgentCore Runtime (MCP, no auth)
                  │
                  └─── Business automation tools (store_lead, ...)
```

## MCP Server & Available Tools

The agent connects to the `agentrep-mcp` server — a stateless streamable-HTTP MCP server hosted on AgentCore Runtime. No authorization is configured at this time. Tools are discovered dynamically at runtime via `client.list_tools_sync()`.

| Tool | Description |
|---|---|
| `store_lead` | Stores a customer lead with `session_id`, `email`, `reason`, and optional `region` |

> Tools are defined in the `agentrep-mcp` project. Update that project's gateway target schema to add or modify tools.

## Memory

The agent uses **AgentCore Memory** (`worker_Memory`) for **short-term memory** — storing raw conversation turns for the duration of the current session. No extraction strategies are configured, so nothing is persisted across sessions.

The memory is implemented via a `ShortTermMemoryHook` (`HookProvider`) following the official AgentCore pattern:

- **On agent start** — the last 10 conversation turns for the current `session_id` are retrieved via `get_last_k_turns` and injected into the system prompt.
- **On each message** — the new message is saved via `create_event`, keyed by `user_id` and `session_id`.

Memory events expire after **7 days**. The memory ID is injected at runtime via the `BEDROCK_AGENTCORE_MEMORY_ID` environment variable. If the variable is not set, the hook is skipped and the agent operates without memory.

---

## Knowledge Base

> **Not yet implemented.** This section describes the planned integration.

The agent will connect to an **Amazon Bedrock Knowledge Base** to retrieve up-to-date company data — such as product catalog, pricing, policies, and FAQs — at query time. This enables the agent to answer customer questions grounded in current company information without retraining the model.

Planned integration approach:
- The Knowledge Base will be backed by an S3 data source synced with company documents
- Retrieval will use semantic search via Bedrock's managed embeddings
- Retrieved chunks will be injected into the agent's context alongside user memory before generating a response

## Project Structure

```
agentrep-worker/
├── src/
│   ├── main.py                 # Agent entrypoint — Strands agent with MCP tools and memory
│   ├── mcp_client/
│   │   └── client.py           # MCP client for AgentCore Gateway (no auth)
│   └── model/
│       └── load.py             # Bedrock model loader (Meta Llama 3 8B via global inference profile)
├── tests/
│   └── test_main.py
├── terraform/
│   ├── main.tf                 # Provider config and outputs
│   ├── variables.tf            # Input variables
│   ├── bedrock_agentcore.tf    # ECR, IAM, Memory, Runtime & endpoints
│   └── terraform.tfvars        # Variable values (set mcp_runtime_url here)
├── Dockerfile                  # Non-root container image with OpenTelemetry instrumentation
├── pyproject.toml              # Project metadata and dependencies (Poetry)
├── poetry.lock                 # Locked dependency versions
└── README.md
```

---

## Prerequisites

- Python 3.10+
- [Poetry](https://python-poetry.org/docs/#installation) (`pipx install poetry`)
- AWS CLI configured (`aws configure`)
- Docker (only needed for local container testing or manual image builds)
- Access to Amazon Bedrock AgentCore in your AWS account
- A deployed `agentrep-mcp` instance — its runtime URL is required as a Terraform variable

---

## Dependency Management (Poetry)

### Install all dependencies (including dev)

```bash
poetry install
```

### Install production dependencies only

```bash
poetry install --only main
```

### Add a new dependency

```bash
poetry add <package>
```

### Add a dev dependency

```bash
poetry add --group dev <package>
```

### Remove a dependency

```bash
poetry remove <package>
```

### Update dependencies

```bash
poetry update
```

---

## Deploying to Amazon Bedrock AgentCore Runtime

### Terraform (Infrastructure as Code)

Terraform manages the full infrastructure: ECR repository, Docker image build and push, IAM execution role, AgentCore Memory, and the Runtime with DEV and PROD endpoints.

#### Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.2
- Docker (must be running — Terraform builds and pushes the image locally)
- AWS CLI configured (`aws configure`)
- Deployed `agentrep-mcp` stack (to get its runtime URL)

#### 1. Navigate to the terraform directory

```bash
cd terraform
```

#### 2. Review and customize variables

Edit [terraform/terraform.tfvars](terraform/terraform.tfvars) with values from your `agentrep-mcp` deployment:

```hcl
app_name              = "worker"
agent_runtime_version = "1"
mcp_runtime_url       = "https://bedrock-agentcore.<region>.amazonaws.com/runtimes/<url-encoded-arn>/invocations"
```

| Variable | Description |
|---|---|
| `app_name` | Name prefix for all created resources |
| `agent_runtime_version` | AgentCore Runtime version pinned to the PROD endpoint |
| `mcp_runtime_url` | Invocation URL of the `agentrep-mcp` AgentCore Runtime |

#### 3. Initialize Terraform

```bash
terraform init
```

#### 4. Preview the changes

```bash
terraform plan
```

#### 5. Deploy

```bash
terraform apply
```

Terraform will:
1. Create an ECR repository (`bedrock-agentcore/worker`)
2. Build the Docker image from the project root and push it to ECR
3. Create an IAM execution role with all required AgentCore permissions
4. Create an AgentCore Memory resource (`worker_Memory`) for short-term conversation storage
5. Create the AgentCore Runtime (`worker_Agent`) with `PUBLIC` network mode
6. Create DEV and PROD endpoints

#### 6. Redeploy after code changes

Terraform detects changes to any file under `src/` via a content hash. Simply run:

```bash
terraform apply
```

#### 7. Destroy all resources

```bash
terraform destroy
```

---

## Invoking the Agent

Navigate to the **Test Console** page in the Bedrock AgentCore AWS console. Select the `worker_Agent` runtime and the `DEFAULT` version. Provide an input:

```json
{"prompt": "What promotions are available for me?"}
```

---

## Environment Variables

| Variable | Description |
|---|---|
| `AWS_REGION` | AWS region for Bedrock and AgentCore services |
| `BEDROCK_AGENTCORE_MEMORY_ID` | AgentCore Memory resource ID (injected by Terraform) |
| `MCP_SERVER_URL` | Invocation URL of the `agentrep-mcp` AgentCore Runtime |

---

## Observability

The server uses `aws-opentelemetry-distro` for automatic instrumentation. Traces are forwarded to AWS X-Ray when running inside AgentCore Runtime.

The `Dockerfile` entrypoint wraps the agent with `opentelemetry-instrument`:

```dockerfile
CMD ["opentelemetry-instrument", "python", "-m", "src.main"]
```

Logs are available in CloudWatch under:
```
/aws/bedrock-agentcore/runtimes/<runtime-id>
```

---

## AgentCore Best Practices Applied

- **Strands agent framework** — `Agent` from `strands` with Bedrock model, MCP tools, and memory session manager wired together.
- **AgentCore Memory (STM)** — `ShortTermMemoryHook` saves and retrieves raw conversation turns within the current session via `MemoryClient`, with no cross-session extraction.
- **MCP tool discovery** — Tools are listed dynamically at invocation time via `client.list_tools_sync()`, so adding tools to `agentrep-mcp` requires no agent code changes.
- **Non-root container user** — Dockerfile creates and runs as `bedrock_agentcore` (UID 1000).
- **OpenTelemetry** — `aws-opentelemetry-distro` enabled for distributed tracing via X-Ray.
- **Structured logging** — `BedrockAgentCoreApp` logger forwarded to CloudWatch.
- **Streaming responses** — `agent.stream_async()` streams response chunks back to the caller as they are generated.

---

## Resources

**Amazon Bedrock AgentCore**
- [AgentCore Runtime — What is Bedrock AgentCore](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/what-is-bedrock-agentcore.html)

- [AgentCore Memory — Short-term and long-term memory](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/memory.html)

- [AgentCore Observability — Built-in instrumentation](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-configure.html)


**Amazon Bedrock**
- [Bedrock cross-region inference profiles](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles-support.html)

