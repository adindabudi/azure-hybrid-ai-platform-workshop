"""LangChain agent with **manual** OpenTelemetry instrumentation.

This is the "before" state for M4.1 — we hand-roll spans around each
LangChain call. It works, but every new tool/chain needs another
``with tracer.start_as_current_span(...)`` block, and the OTel attribute
schema for GenAI is not standardized across the team.

The "after" version (``after.py``) replaces all of this with three
lines from the Microsoft Agents 365 LangChain extension.
"""

from __future__ import annotations

import asyncio
import os

from langchain.agents import AgentExecutor, create_tool_calling_agent
from langchain.tools import tool
from langchain_core.prompts import ChatPromptTemplate
from langchain_openai import AzureChatOpenAI
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import (
    BatchSpanProcessor,
    ConsoleSpanExporter,
)


# Manual OTel boilerplate — one provider, one exporter, one tracer.
trace.set_tracer_provider(TracerProvider())
trace.get_tracer_provider().add_span_processor(
    BatchSpanProcessor(ConsoleSpanExporter())
)
tracer = trace.get_tracer("complaint-triage-langchain-before")


@tool
def classify_complaint(text: str) -> dict:
    """Classify a customer complaint into category + urgency."""
    # Manual span for the tool call. Without this, you'd see only the
    # outer agent span and have no idea which tool ran or how long it took.
    with tracer.start_as_current_span("tool.classify_complaint") as span:
        span.set_attribute("input.length", len(text))
        text_l = text.lower()
        if any(k in text_l for k in ("card", "atm", "transfer", "kartu")):
            result = {"category": "transactional", "urgency": "high"}
        elif any(k in text_l for k in ("password", "login", "otp", "lupa")):
            result = {"category": "account-access", "urgency": "high"}
        else:
            result = {"category": "general", "urgency": "medium"}
        span.set_attribute("output.category", result["category"])
        span.set_attribute("output.urgency", result["urgency"])
        return result


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
    # Manual outer span around the agent invocation.
    with tracer.start_as_current_span("agent.run") as span:
        span.set_attribute("genai.system", "azure_openai_via_apim")
        span.set_attribute("genai.request.model", os.environ["MODEL_NAME"])
        result = await agent.ainvoke(
            {"input": "Kartu ATM saya tertelan tadi malam, tolong bantu."}
        )
        span.set_attribute("output.length", len(result["output"]))
    print(result["output"])


if __name__ == "__main__":
    asyncio.run(main())
