"""Triage agent — classifies and routes customer support requests.

Used in M4 — Agent Framework. Configured to talk to *any* OpenAI-
compatible endpoint via ``OpenAIChatClient``:

* APIM-fronted Azure OpenAI in Singapore (default — set ``MODEL_TIER=premium``)
* APIM-fronted self-hosted Phi-4-mini on AKS (``MODEL_TIER=cheap``)
* LiteLLM proxy (point ``APIM_URL`` at the LiteLLM service)
* Foundry Local on your laptop (swap ``FoundryLocalClient`` in)

Switching backends is one env-var change — see Step 4 of the M4 docs.

API references:
* https://learn.microsoft.com/agent-framework/agents/providers/openai
* https://learn.microsoft.com/agent-framework/support/upgrade/python-2026-significant-changes
"""

from __future__ import annotations

import asyncio
import os

# After the python-1.0.0rc6 split, OpenAI/Azure-OpenAI clients live in
# the agent_framework.openai package. Install ``agent-framework`` (meta)
# or ``agent-framework-openai`` to bring this in.
from agent_framework.openai import OpenAIChatClient


def classify_complaint(text: str) -> dict:
    """Local Python tool the agent can call.

    Returns a category and urgency. In production this would query your
    CRM or ticketing system.
    """
    text_l = text.lower()
    if any(k in text_l for k in ("card", "atm", "transfer", "kartu")):
        category, urgency = "transactional", "high"
    elif any(k in text_l for k in ("password", "login", "otp", "lupa")):
        category, urgency = "account-access", "high"
    elif any(k in text_l for k in ("statement", "balance", "history", "saldo")):
        category, urgency = "informational", "low"
    else:
        category, urgency = "general", "medium"
    return {"category": category, "urgency": urgency}


def build_agent():
    """Configure the chat client + agent.

    APIM_URL and APIM_KEY come from the workshop bootstrap. Switching
    backends means changing only these two env vars — see Step 4.
    """
    client = OpenAIChatClient(
        model=os.environ["MODEL_NAME"],
        azure_endpoint=os.environ["APIM_URL"],
        api_version="2024-10-21",
        api_key=os.environ["APIM_KEY"],
        # When MODEL_TIER is set, APIM uses it to route to the right
        # backend (gpt-5-mini in Singapore vs Phi-4-mini on AKS).
        default_headers={"x-model-tier": os.environ.get("MODEL_TIER", "premium")},
    )

    # `client.create_agent(...)` is the convenience method that returns
    # a configured ChatAgent — equivalent to:
    #   from agent_framework import ChatAgent
    #   ChatAgent(chat_client=client, name=..., instructions=..., tools=[...])
    return client.create_agent(
        name="ComplaintTriage",
        instructions=(
            "You triage customer support requests. "
            "Use the classify_complaint tool to identify the category and "
            "urgency, then respond with a one-sentence summary of next steps. "
            "Always reply in the customer's language."
        ),
        tools=[classify_complaint],
    )


async def main() -> None:
    agent = build_agent()
    response = await agent.run(
        "Halo, kartu ATM saya tertelan di Surabaya tadi malam. Tolong bantu."
    )
    # `AgentRunResponse.text` is the assembled assistant text.
    print(response.text)


if __name__ == "__main__":
    asyncio.run(main())
