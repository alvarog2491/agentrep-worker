import os
import boto3
from opentelemetry import baggage
from opentelemetry import context as otel_context
from strands import Agent, tool
from strands.hooks import AgentInitializedEvent, HookProvider, MessageAddedEvent
from bedrock_agentcore import BedrockAgentCoreApp
from bedrock_agentcore.memory import MemoryClient
from .mcp_client.client import get_mcp_client
from .model.load import load_model

MEMORY_ID = os.getenv("BEDROCK_AGENTCORE_MEMORY_ID")
REGION = os.getenv("AWS_REGION", "us-east-1")
KB_ID = os.getenv("KNOWLEDGE_BASE_ID")

memory_client = MemoryClient(region_name=REGION)
kb_client = boto3.client("bedrock-agent-runtime", region_name=REGION) if KB_ID else None

app = BedrockAgentCoreApp()
log = app.logger

if KB_ID:
    log.info("Knowledge base enabled", extra={"knowledge_base_id": KB_ID})
else:
    log.warning("KNOWLEDGE_BASE_ID not set — running without knowledge base")

if MEMORY_ID:
    log.info("Memory enabled", extra={"memory_id": MEMORY_ID, "region": REGION})
else:
    log.warning("MEMORY_ID not set — running without short-term memory")


@tool
def search_knowledge_base(query: str) -> str:
    """Search the company knowledge base for information about products, services,
    pricing, policies, and FAQs that the model was not trained on.
    Use this whenever the customer asks something that requires up-to-date or
    company-specific information."""
    response = kb_client.retrieve(
        knowledgeBaseId=KB_ID,
        retrievalQuery={"text": query},
        retrievalConfiguration={
            "vectorSearchConfiguration": {"numberOfResults": 5}
        },
    )
    results = response.get("retrievalResults", [])
    if not results:
        return "No relevant information found in the knowledge base."
    return "\n\n".join(
        r["content"]["text"] for r in results if r.get("content", {}).get("text")
    )


def _extract_text(content) -> str:
    """Extract plain text from a Strands message content value."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        texts = [
            block["text"]
            for block in content
            if isinstance(block, dict) and block.get("type") == "text" and block.get("text")
        ]
        return " ".join(texts)
    return ""


class ShortTermMemoryHook(HookProvider):
    """Loads and saves conversation turns for the current session only."""

    def on_agent_initialized(self, event: AgentInitializedEvent):
        if not MEMORY_ID:
            return
        session_id = event.agent.state.get("session_id") or "default"
        log.info("Loading conversation history", extra={"session_id": session_id})
        turns = memory_client.get_last_k_turns(
            memory_id=MEMORY_ID,
            actor_id="user",
            session_id=session_id,
            k=10,
        )
        if turns:
            log.info("Injecting conversation history", extra={"session_id": session_id, "turns": len(turns)})
            context = "\n".join(
                f"{m['role']}: {m['content']['text']}"
                for turn in turns
                for m in turn
            )
            event.agent.system_prompt += f"\n\nConversation so far:\n{context}"
        else:
            log.info("No previous conversation history found", extra={"session_id": session_id})

    def on_message_added(self, event: MessageAddedEvent):
        if not MEMORY_ID:
            return
        session_id = event.agent.state.get("session_id") or "default"
        msg = event.agent.messages[-1]
        role = msg.get("role")
        # Only persist user and assistant text — skip tool use / tool result messages
        if role not in ("user", "assistant"):
            return
        text = _extract_text(msg.get("content", ""))
        if not text.strip():
            return
        log.info("Saving message to memory", extra={"session_id": session_id, "role": role})
        memory_client.create_event(
            memory_id=MEMORY_ID,
            actor_id="user",
            session_id=session_id,
            messages=[(text, role)],
        )

    def register_hooks(self, registry):
        registry.add_callback(AgentInitializedEvent, self.on_agent_initialized)
        registry.add_callback(MessageAddedEvent, self.on_message_added)


@app.entrypoint
async def invoke(payload, context):
    session_id = getattr(context, "session_id", "default")
    prompt = payload.get("prompt")
    log.info("Invocation received", extra={"session_id": session_id, "prompt": prompt})

    ctx = baggage.set_baggage("session.id", session_id)
    context_token = otel_context.attach(ctx)

    with get_mcp_client() as client:
        tools = client.list_tools_sync()
        log.info("MCP tools loaded", extra={"tools": [t.tool_name for t in tools]})
        if KB_ID:
            log.info("Knowledge base tool enabled", extra={"knowledge_base_id": KB_ID})

        all_tools = tools + ([search_knowledge_base] if KB_ID else [])
        agent = Agent(
            model=load_model(),
            system_prompt=(
                "You are a customer experience agent responsible for collecting leads. "
                "Your goal is to gather the customer's contact information and the reason for their interest. "
                "As soon as you have collected a lead — meaning you have at minimum the customer's email and reason — "
                "you MUST immediately call the store_lead tool to save it before continuing the conversation. "
                "Do not wait until the end of the conversation to store the lead.\n\n"
                "CRITICAL RULE — KNOWLEDGE BASE: Whenever the user asks ANY question about facts, details, "
                "codes, numbers, products, services, policies, procedures, or anything specific, you MUST "
                "invoke the search_knowledge_base tool IN THIS SAME RESPONSE before writing your answer. "
                "Do NOT say you will search later. Do NOT ask for clarification before searching. "
                "Call search_knowledge_base immediately, then use the result to answer. "
                "If the search returns no results, then honestly say you could not find the information."
            ),
            tools=all_tools,
            hooks=[ShortTermMemoryHook()] if MEMORY_ID else [],
            state={"session_id": session_id},
        )

        log.info("Streaming agent response", extra={"session_id": session_id})
        async for event in agent.stream_async(prompt):
            if "data" in event and isinstance(event["data"], str):
                yield event["data"]

    otel_context.detach(context_token)
    log.info("Invocation complete", extra={"session_id": session_id})


if __name__ == "__main__":
    app.run()
