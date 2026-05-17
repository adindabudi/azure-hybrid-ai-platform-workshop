"""Triage agent — classifies and routes customer support requests.

Used in M4 — Agent Framework. Configured to talk to *any* OpenAI-
compatible endpoint via ``OpenAIChatCompletionClient``:

* APIM-fronted Azure OpenAI in Singapore (default — ``MODEL_TIER=premium``)
* APIM-fronted self-hosted Phi-4-mini on AKS (``MODEL_TIER=cheap``)
* LiteLLM proxy (point ``APIM_URL`` at the LiteLLM service)
* Foundry Local on your laptop (swap in ``FoundryLocalClient``)

Switching backends is one env-var change — see Step 4 of the M4 docs.

Why ``OpenAIChatCompletionClient`` and not ``OpenAIChatClient``?
----------------------------------------------------------------
``agent-framework`` 1.4.0 split the OpenAI client surface in two:

* ``OpenAIChatClient`` → talks to the **OpenAI Responses API**
  (``/v1/responses``). Azure OpenAI exposes it, but the APIM
  Developer SKU here imports the ``inference.json`` spec from
  ``Azure/azure-rest-api-specs``, which currently only includes
  ``/openai/deployments/{name}/chat/completions``. So requests to
  ``/responses`` 404 at the APIM gateway.
* ``OpenAIChatCompletionClient`` → talks to the **chat completions
  API**, which is what APIM exposes today.

Use ``OpenAIChatCompletionClient`` for any APIM-fronted call. Use
``OpenAIChatClient`` only when calling Azure OpenAI directly without
APIM in front of it.

API references:
* https://learn.microsoft.com/agent-framework/agents/providers/openai
* https://learn.microsoft.com/agent-framework/support/upgrade/python-2026-significant-changes
"""

from __future__ import annotations

import asyncio
import os
import warnings

# Silence the SDK's "X is experimental" boot-time chatter so the M4
# console stays readable. They are accurate but noisy in a workshop.
warnings.filterwarnings("ignore", message=".*is experimental.*")

from agent_framework import Agent  # noqa: E402
from agent_framework.openai import OpenAIChatCompletionClient  # noqa: E402


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


def build_agent() -> Agent:
    """Configure the chat client + agent.

    ``APIM_URL`` and ``APIM_KEY`` come from the workshop bootstrap.
    Switching backends means changing only those two env vars — see
    Step 4 in the M4 docs.
    """
    client = OpenAIChatCompletionClient(
        model=os.environ["MODEL_NAME"],
        azure_endpoint=os.environ["APIM_URL"],
        api_version="2024-10-21",
        api_key=os.environ["APIM_KEY"],
        # When MODEL_TIER is set, APIM uses it to route to the right
        # backend (gpt-5-mini in Singapore vs Phi-4-mini on AKS).
        default_headers={
            "x-model-tier": os.environ.get("MODEL_TIER", "premium"),
        },
    )

    # In 1.4.0 the convenience ``client.create_agent(...)`` helper was
    # removed. Construct an ``Agent`` directly — the client is the
    # first keyword argument.
    return Agent(
        client=client,
        name="ComplaintTriage",
        instructions=(
            "You triage customer support requests. "
            "Use the classify_complaint tool to identify the category and "
            "urgency, then respond with a one-sentence summary of next "
            "steps. Always reply in the customer's language."
        ),
        tools=[classify_complaint],
    )


async def main() -> None:
    agent = build_agent()
    response = await agent.run(
        "Halo, kartu ATM saya tertelan di Surabaya tadi malam. Tolong bantu."
    )
    # ``AgentResponse.text`` is the assembled assistant text.
    print(response.text)


if __name__ == "__main__":
    asyncio.run(main())
