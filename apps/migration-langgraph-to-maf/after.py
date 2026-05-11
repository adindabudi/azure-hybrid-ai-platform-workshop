"""Same LangChain agent as ``before.py`` — but with Microsoft Agents 365
LangChain auto-instrumentation.

The two key differences from ``before.py``:

1. We ``configure(...)`` once, with our service identity. This wires up
   the OTel SDK + the GenAI semantic conventions emitter, and sends
   spans to wherever ``OTEL_EXPORTER_OTLP_ENDPOINT`` points (Aspire
   dashboard locally, Azure Monitor in prod via
   ``configure_azure_monitor()``).

2. ``CustomLangChainInstrumentor()`` patches LangChain at import time —
   every chain, tool, and LLM call gets a span automatically with the
   correct ``gen_ai.*`` attributes. Zero per-tool boilerplate.

Net result: same agent behavior, ~50 fewer lines, schema-conformant
telemetry that lights up in Foundry / Application Insights without
any custom dashboards.

Docs:
* https://learn.microsoft.com/microsoft-agents/agents-365/observability/extensions/langchain
"""

from __future__ import annotations

import asyncio
import os

from langchain.agents import AgentExecutor, create_tool_calling_agent
from langchain.tools import tool
from langchain_core.prompts import ChatPromptTemplate
from langchain_openai import AzureChatOpenAI

# Microsoft Agents 365 — observability core + LangChain extension.
from microsoft_agents_a365.observability.core import configure
from microsoft_agents_a365.observability.extensions.langchain import (
    CustomLangChainInstrumentor,
)


# Step 1 — Configure observability once at process start. Reads
# OTEL_EXPORTER_OTLP_ENDPOINT and friends from env.
configure(
    service_name="complaint-triage-langchain",
    service_namespace="ai.workshop",
)

# Step 2 — Enable LangChain auto-instrumentation.
# `.instrument()` is the standard OTel BaseInstrumentor activation; for
# `CustomLangChainInstrumentor` it's idempotent — re-running this script
# does NOT double-wrap.
CustomLangChainInstrumentor().instrument()


@tool
def classify_complaint(text: str) -> dict:
    """Classify a customer complaint into category + urgency.

    Notice — no manual span here. The instrumentor wraps every
    ``@tool`` invocation automatically.
    """
    text_l = text.lower()
    if any(k in text_l for k in ("card", "atm", "transfer", "kartu")):
        return {"category": "transactional", "urgency": "high"}
    if any(k in text_l for k in ("password", "login", "otp", "lupa")):
        return {"category": "account-access", "urgency": "high"}
    return {"category": "general", "urgency": "medium"}


def build_agent() -> AgentExecutor:
    llm = AzureChatOpenAI(
        azure_endpoint=os.environ["APIM_URL"],
        api_key=os.environ["APIM_KEY"],
        azure_deployment=os.environ["MODEL_NAME"],
        api_version="2024-10-21",
        default_headers={"x-model-tier": os.environ.get("MODEL_TIER", "premium")},
    )
    prompt = ChatPromptTemplate.from_messages(
        [
            ("system", "You triage customer complaints. Use tools when needed."),
            ("human", "{input}"),
            ("placeholder", "{agent_scratchpad}"),
        ]
    )
    agent = create_tool_calling_agent(llm, [classify_complaint], prompt)
    return AgentExecutor(agent=agent, tools=[classify_complaint], verbose=True)


async def main() -> None:
    agent = build_agent()
    # No manual span here either — the instrumentor emits a root span
    # for AgentExecutor.ainvoke automatically.
    result = await agent.ainvoke(
        {"input": "Kartu ATM saya tertelan tadi malam, tolong bantu."}
    )
    print(result["output"])


if __name__ == "__main__":
    asyncio.run(main())
