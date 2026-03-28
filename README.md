# agentrep-worker — Customer Experience Agent on Amazon Bedrock AgentCore

A conversational AI agent built for **customer experience** and **lead collection** use cases. It connects to the [`agentrep-mcp`](https://github.com/alvarog2491/agentrep-mcp) MCP server to access business automation tools, queries an **Amazon Bedrock Knowledge Base** for company-specific information, and uses **AgentCore Memory** for short-term conversation context within a session. Designed to run on **Amazon Bedrock AgentCore Runtime**.

## Contents

- [Architecture](#architecture)
- [Tools](#tools)
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

The worker agent receives a customer prompt, retrieves session memory, connects to the [`agentrep-mcp`](https://github.com/alvarog2491/agentrep-mcp) AgentCore Runtime to discover and invoke MCP tools, queries the Bedrock Knowledge Base for company-specific information, and streams the response back to the caller.

```
Customer Request
      │
      ▼
AgentCore Runtime (worker_Agent)
      │
      ├─── AgentCore Memory (STM) ──► Raw conversation turns for the current session
      │
      ├─── Bedrock Knowledge Base ──► Company data, products, policies, FAQs
      │
      └─── agentrep-mcp AgentCore Runtime (MCP, SigV4 auth)
                  │
                  └─── Business automation tools (store_lead, ...)
```

## Tools

### MCP tools (via [`agentrep-mcp`](https://github.com/alvarog2491/agentrep-mcp))

Tools are discovered dynamically at invocation time via `client.list_tools_sync()`. No hardcoded tool list — adding a tool to [`agentrep-mcp`](https://github.com/alvarog2491/agentrep-mcp) requires no changes here.

| Tool | Description |
|---|---|
| `store_lead` | Stores a customer lead with `session_id`, `email`, `reason`, and optional `region` |

### Built-in tools

| Tool | Description |
|---|---|
| `search_knowledge_base` | Semantic search against the Bedrock Knowledge Base. Active only when `KNOWLEDGE_BASE_ID` is set. |

The agent is prompted to call `search_knowledge_base` immediately whenever a user asks about facts, products, services, codes, policies, or anything company-specific. If the knowledge base returns no results, the agent is instructed to honestly say so rather than hallucinate an answer.

---

## Memory

The agent uses **AgentCore Memory** (`worker_Memory`) for **short-term memory** — storing raw conversation turns for the duration of the current session. No extraction strategies are configured, so nothing is persisted across sessions.

The memory is implemented via a `ShortTermMemoryHook` (`HookProvider`) following the official AgentCore pattern:

- **On agent start** — the last 10 conversation turns for the current `session_id` are retrieved via `get_last_k_turns` and injected into the system prompt.
- **On each message** — the new message is saved via `create_event`, keyed by `actor_id="user"` and `session_id`.

Memory events expire after **7 days**. The memory ID is injected at runtime via `BEDROCK_AGENTCORE_MEMORY_ID`. If the variable is not set, the hook is skipped and the agent operates without memory.

---

## Knowledge Base

The agent connects to an **Amazon Bedrock Knowledge Base** to retrieve up-to-date company data — such as product catalog, pricing, policies, and FAQs — at query time. Retrieval uses semantic search (top-5 results) via Bedrock's managed embeddings.

The `search_knowledge_base` tool is registered only when `KNOWLEDGE_BASE_ID` is set. When it is, the system prompt instructs the agent to:

1. **Always search before answering** any factual or company-specific question — in the same response, without asking for clarification first.
2. **Never hallucinate** — if the search returns no results, the agent tells the user it couldn't find the information and suggests contacting the team directly.

Set `knowledge_base_id` in [terraform/terraform.tfvars](terraform/terraform.tfvars) to enable it. Leave it empty to run without a knowledge base.

---

## Project Structure

```
agentrep-worker/
├── src/
│   ├── main.py                 # Agent entrypoint — Strands agent, MCP tools, KB tool, memory hook
│   ├── mcp_client/
│   │   └── client.py           # SigV4-authenticated MCP client for the AgentCore Gateway
│   └── model/
│       └── load.py             # Bedrock model loader (Meta Llama 3 8B via global inference profile)
├── tests/
│   └── test_main.py
├── terraform/
│   ├── main.tf                 # Provider config and outputs (runtime ID, latest version)
│   ├── variables.tf            # Input variables
│   ├── bedrock_agentcore.tf    # ECR, IAM, Memory, log groups, log delivery, Runtime & endpoints
│   └── terraform.tfvars        # Variable values (set mcp_runtime_url and knowledge_base_id here)
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
- Docker (must be running — Terraform builds and pushes the image locally)
- Access to Amazon Bedrock AgentCore in your AWS account
- A deployed [`agentrep-mcp`](https://github.com/alvarog2491/agentrep-mcp) instance — its runtime URL is required as a Terraform variable

---

## Dependency Management (Poetry)

### Install all dependencies (including dev)

```bash
poetry install
```

### Add a new dependency

```bash
poetry add <package>
```

### Add a dev dependency

```bash
poetry add --group dev <package>
```

---

## Deploying to Amazon Bedrock AgentCore Runtime

### Terraform (Infrastructure as Code)

Terraform manages the full infrastructure: ECR repository, Docker image build and push, IAM execution role, CloudWatch log groups and log delivery, AgentCore Memory, and the Runtime with DEV and PROD endpoints.

#### Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.2
- Docker (must be running — Terraform builds and pushes the image locally)
- AWS CLI configured (`aws configure`)
- Deployed [`agentrep-mcp`](https://github.com/alvarog2491/agentrep-mcp) stack (to get its runtime URL)

#### 1. Navigate to the terraform directory

```bash
cd terraform
```

#### 2. Customize variables

Edit [terraform/terraform.tfvars](terraform/terraform.tfvars):

```hcl
app_name              = "worker"
agent_runtime_version = "1"
mcp_runtime_url       = "https://bedrock-agentcore.<region>.amazonaws.com/runtimes/<url-encoded-arn>/invocations"
knowledge_base_id     = ""   # optional — leave empty to disable the KB tool
```

| Variable | Description |
|---|---|
| `app_name` | Name prefix for all created resources |
| `agent_runtime_version` | Runtime version pinned to the **PROD** endpoint — bump manually to promote |
| `mcp_runtime_url` | Invocation URL of the [`agentrep-mcp`](https://github.com/alvarog2491/agentrep-mcp) AgentCore Runtime |
| `knowledge_base_id` | Bedrock Knowledge Base ID (leave empty to disable) |

#### 3. Initialize, plan, and deploy

```bash
terraform init
terraform plan
terraform apply
```

Terraform will:
1. Create an ECR repository (`bedrock-agentcore/worker`)
2. Build the Docker image from the project root and push it to ECR
3. Create an IAM execution role with all required AgentCore permissions
4. Create CloudWatch log groups and log delivery for application logs
5. Create the AgentCore Runtime (`worker_Agent`) with `PUBLIC` network mode
6. Create **DEV** and **PROD** endpoints (see [Versioning](#versioning) below)

#### 4. Redeploy after code changes

Terraform hashes all files under `src/` plus `Dockerfile`, `pyproject.toml`, and `poetry.lock`. Any change to those files triggers a new Docker build, a new ECR push, and a new AgentCore runtime version on the next apply:

```bash
terraform apply
```

#### 5. Destroy all resources

```bash
terraform destroy
```

---

### Versioning

Every `terraform apply` that detects a change in `src/` or the build files creates a **new AgentCore runtime version** automatically.

| Endpoint | Tracks | Behavior |
|---|---|---|
| `DEV` | `agentcore_runtime.agent_runtime_version` | Always the latest deployed version — use this to test |
| `PROD` | `var.agent_runtime_version` (tfvars) | Stable — only updates when you bump the variable |

After applying, Terraform prints the latest version number:

```
Outputs:
  agentcore_runtime_version = "2"
```

To promote to PROD, update `agent_runtime_version = "2"` in `terraform.tfvars` and run `terraform apply` again.

---

## Invoking the Agent

Use the **Test Console** in the Bedrock AgentCore AWS console. Select `worker_Agent`, pick the `DEV` or `PROD` endpoint, and send:

```json
{"prompt": "What promotions are available for me?"}
```

---

## Environment Variables

| Variable | Description |
|---|---|
| `AWS_REGION` | AWS region for Bedrock and AgentCore services (default: `us-east-1`) |
| `BEDROCK_AGENTCORE_MEMORY_ID` | AgentCore Memory resource ID (injected by Terraform) |
| `MCP_SERVER_URL` | Invocation URL of the [`agentrep-mcp`](https://github.com/alvarog2491/agentrep-mcp) AgentCore Runtime (injected by Terraform) |
| `KNOWLEDGE_BASE_ID` | Bedrock Knowledge Base ID — enables `search_knowledge_base` tool (injected by Terraform) |
| `AGENT_OBSERVABILITY_ENABLED` | Set to `true` to activate ADOT-based tracing (injected by Terraform) |

---

## Observability

Observability is configured automatically by Terraform with no manual console steps required.

### Tracing

The Dockerfile uses `opentelemetry-instrument` as the container entrypoint, and `AGENT_OBSERVABILITY_ENABLED=true` is injected at runtime:

```dockerfile
CMD ["opentelemetry-instrument", "python", "-m", "src.main"]
```

The ADOT SDK (`aws-opentelemetry-distro`) sends distributed traces to **AWS X-Ray**. The IAM execution role includes all required `xray:Put*` permissions.

### Application log delivery

Terraform creates a CloudWatch log group and a full log delivery chain:

| Resource | Name |
|---|---|
| Log group | `/aws/bedrock-agentcore/runtimes/worker/app-logs` (30-day retention) |
| Delivery source | `worker-agentcore-runtime` (`APPLICATION_LOGS`) |
| Delivery destination | `worker-agentcore-runtime-cw` |

### Runtime container logs

Standard container stdout/stderr logs are available in CloudWatch under:
```
/aws/bedrock-agentcore/runtimes/<runtime-id>
```

---

## AgentCore Best Practices Applied

- **Strands agent framework** — `Agent` from `strands` with Bedrock model, MCP tools, KB tool, and memory hook.
- **AgentCore Memory (STM)** — `ShortTermMemoryHook` saves and retrieves raw conversation turns within the current session via `MemoryClient`.
- **Knowledge Base grounding** — Agent is instructed to always consult the KB before answering and to never hallucinate when the KB returns no results.
- **MCP tool discovery** — Tools are listed dynamically at invocation time via `client.list_tools_sync()`, so adding tools to [`agentrep-mcp`](https://github.com/alvarog2491/agentrep-mcp) requires no agent code changes.
- **SigV4 authentication** — MCP client authenticates to the AgentCore Gateway using the execution role's credentials.
- **Non-root container user** — Dockerfile creates and runs as `bedrock_agentcore` (UID 1000).
- **OpenTelemetry** — `aws-opentelemetry-distro` + `AGENT_OBSERVABILITY_ENABLED=true` for distributed tracing via X-Ray.
- **Structured logging** — `BedrockAgentCoreApp` logger forwarded to CloudWatch via managed log delivery.
- **Streaming responses** — `agent.stream_async()` streams response chunks back to the caller as they are generated.
- **DEV/PROD endpoint separation** — DEV always tracks the latest version; PROD is promoted manually by bumping `agent_runtime_version` in `terraform.tfvars`.

---

## Resources

**Amazon Bedrock AgentCore**
- [AgentCore Runtime — What is Bedrock AgentCore](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/what-is-bedrock-agentcore.html)
- [AgentCore Memory — Short-term and long-term memory](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/memory.html)
- [AgentCore Observability — Built-in instrumentation](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-configure.html)

**Amazon Bedrock**
- [Bedrock Knowledge Bases](https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-base.html)
- [Bedrock cross-region inference profiles](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles-support.html)
