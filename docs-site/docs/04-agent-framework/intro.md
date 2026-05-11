---
title: 4.0 — Agent Framework overview
sidebar_position: 1
---

# M4 — Agent Framework: build, connect, compose

## What you will accomplish

In this 75-minute module you will:

- Build a working agent with the Python Microsoft Agent Framework (MAF).
- Point that same agent at **four different runtimes** by changing one
  env var: Azure OpenAI in Singapore, the self-hosted SLM on AKS,
  [LiteLLM](https://github.com/BerriAI/litellm), and Foundry Local on
  your laptop.
- Add a multi-step **Workflow** (Triage → Specialist → Compliance Review)
  with file-based checkpoint storage.
- Optionally migrate an existing LangChain chain to MAF with three lines
  of code — covered separately in [4.1](./migrate-from-langgraph).

## Prerequisites

- M0.5 Python stack installed.
- M1 + M2 done — gateway is reachable, content safety wired.
- One free terminal for `agent-framework devui` (the visual debugger).

## Step 1 — Smoke-test the Python stack

```bash
source .venv/bin/activate

python - <<'PY'
import agent_framework
from agent_framework import OpenAIChatClient

print("agent_framework", agent_framework.__version__)
print("OpenAIChatClient module", OpenAIChatClient.__module__)
PY
```

**Expected output**

```
agent_framework 1.3.0
OpenAIChatClient module agent_framework
```

If the import fails, revisit [M0 Step 6](../00-intro/setup.md).

## Step 2 — Your first MAF agent

Create `apps/agent-complaint-triage/agent.py`:

```python title="apps/agent-complaint-triage/agent.py"
"""Triage agent — classifies and routes customer support requests."""

import asyncio
import os

from agent_framework import Agent, OpenAIChatClient


def classify_complaint(text: str) -> dict:
    """Local Python tool the agent can call.

    Returns a category and urgency. In production this would query your
    CRM or ticketing system.
    """
    text_l = text.lower()
    if any(k in text_l for k in ("card", "atm", "transfer")):
        category, urgency = "transactional", "high"
    elif any(k in text_l for k in ("password", "login", "otp")):
        category, urgency = "account-access", "high"
    elif any(k in text_l for k in ("statement", "balance", "history")):
        category, urgency = "informational", "low"
    else:
        category, urgency = "general", "medium"
    return {"category": category, "urgency": urgency}


def build_agent() -> Agent:
    """Configure the chat client + agent.

    APIM_URL and APIM_KEY come from the workshop bootstrap. Switching
    backends means changing only these two env vars — see Step 4.
    """
    client = OpenAIChatClient(
        model=os.environ["MODEL_NAME"],
        azure_endpoint=os.environ["APIM_URL"],
        api_version="2024-10-21",
        api_key=os.environ["APIM_KEY"],
    )

    return Agent(
        client,
        name="ComplaintTriage",
        instructions=(
            "You triage customer support requests. "
            "Use the classify_complaint tool to identify the category and "
            "urgency, then respond with a one-sentence summary of next steps. "
            "Always reply in the customer's language."
        ),
        tools=[classify_complaint],
    )


async def main():
    agent = build_agent()
    response = await agent.run(
        "Halo, kartu ATM saya tertelan di Surabaya tadi malam. Tolong bantu."
    )
    print(response.output)


if __name__ == "__main__":
    asyncio.run(main())
```

## Step 3 — Run it against the gateway

```bash
# APIM_URL is the same APIM_GATEWAY_URL from your handout
export APIM_URL="$APIM_GATEWAY_URL"
export MODEL_NAME="gpt-5-mini"

python apps/agent-complaint-triage/agent.py
```

**Expected output** — one short sentence in the same language as the
input, e.g.

```
Saya catat sebagai transactional/urgency high — mohon hubungi customer
service prioritas dan saya akan eskalasi sekarang.
```

You should also see in **Application Insights → Transaction search** a
new trace with `service.name=ComplaintTriage` and one tool call to
`classify_complaint`.

## Step 4 — Same agent, four runtimes

The interesting design point of MAF: the **same `OpenAIChatClient` class**
works against four different backends. You don't need a separate
`AzureOpenAIChatClient` or `LiteLLMChatClient`.

### (a) APIM-fronted AOAI Singapore — what you just ran

```bash
export APIM_URL="$APIM_GATEWAY_URL"           # from M0 handout
export MODEL_NAME="gpt-5-mini"
python apps/agent-complaint-triage/agent.py
```

### (b) APIM-fronted self-hosted Phi-4-mini

Set the model-tier header so APIM routes to the SLM backend. Change
`agent.py` to add the header to the client. Easiest: use `default_headers`:

```python
client = OpenAIChatClient(
    model=os.environ["MODEL_NAME"],
    azure_endpoint=os.environ["APIM_URL"],
    api_version="2024-10-21",
    api_key=os.environ["APIM_KEY"],
    default_headers={"x-model-tier": os.environ.get("MODEL_TIER", "premium")},
)
```

Then:

```bash
export MODEL_TIER=cheap
export MODEL_NAME=phi-4-mini-instruct
python apps/agent-complaint-triage/agent.py
```

The model output may be less polished — Phi-4-mini is a 3.8B-parameter
model — but the tool calling works identically.

### (c) LiteLLM standalone

Deploy LiteLLM as a sidecar OAI-compatible proxy in your namespace
(facilitator-built image, or
[upstream](https://github.com/BerriAI/litellm)):

```bash
kubectl apply -n "$NS" -f apps/litellm-comparison/deployment.yaml
LITELLM_IP=$(kubectl get svc litellm -n "$NS" \
  -o jsonpath='{.spec.clusterIP}')

# Point the agent at LiteLLM instead of APIM
export APIM_URL="http://${LITELLM_IP}:4000"
export APIM_KEY=$(kubectl get secret litellm-creds -n "$NS" \
  -o jsonpath='{.data.master-key}' | base64 -d)
export MODEL_NAME=gpt-5-mini-via-litellm

python apps/agent-complaint-triage/agent.py
```

### (d) Foundry Local on your laptop

For the no-network-needed path — useful for an architect's laptop demo —
use [Foundry Local](https://learn.microsoft.com/azure/ai-foundry/foundry-local/).
This requires `agent-framework-foundry-local` (already in M0's pip
install).

```python
from agent_framework.foundry import FoundryLocalClient

client = FoundryLocalClient(model="phi-4-mini")
agent = Agent(client, name="ComplaintTriage", instructions=..., tools=[...])
```

### Verify all four runtimes

Run the agent against each in turn. The output should be coherent in all
four cases. The model field returned (and visible in App Insights traces)
tells you which backend served the request.

## Step 5 — Launch DevUI

`agent-framework-devui` is the visual debugger for MAF agents. It graphs
multi-step workflows, shows tool calls inline, and exposes an
OpenAI-compatible HTTP endpoint for ad-hoc testing.

```bash
# In a separate terminal
devui apps/ --port 8080 --instrumentation
```

Open [http://localhost:8080](http://localhost:8080). Pick `ComplaintTriage` from the sidebar
and send a test message. Each tool call is shown as a separate span; the
trace timeline matches what you see in Application Insights.

## Step 6 — Multi-agent Workflow

When one agent can't do the job, MAF Workflows let you connect several
into a directed graph. Use this when:

- Each step has different system prompts (triage vs. legal review).
- You need deterministic routing (always Triage → Specialist).
- You want **checkpointing** so the workflow survives a pod restart.

Create `apps/agent-complaint-triage/workflow.py`:

```python title="apps/agent-complaint-triage/workflow.py"
import asyncio
import os
from pathlib import Path

from agent_framework import (
    Agent, OpenAIChatClient,
    WorkflowBuilder, FileCheckpointStorage,
)


def make_client():
    return OpenAIChatClient(
        model="gpt-5-mini",
        azure_endpoint=os.environ["APIM_URL"],
        api_version="2024-10-21",
        api_key=os.environ["APIM_KEY"],
    )


client = make_client()

triage = Agent(client, name="Triage",
               instructions="Classify into transactional|account|info|general.")
specialist = Agent(client, name="Specialist",
                   instructions="Generate a draft customer reply.")
compliance = Agent(client, name="Compliance",
                   instructions=(
                     "Review the draft for regulatory language. "
                     "Return APPROVED:<reply> or REJECTED:<reason>."
                   ))

workflow = (
    WorkflowBuilder(start_executor=triage)
    .add_executor(specialist)
    .add_executor(compliance)
    .add_edge(triage, specialist)
    .add_edge(specialist, compliance)
    .with_checkpoint_storage(
        FileCheckpointStorage(Path("./.checkpoints").resolve())
    )
    .build()
)


async def main():
    result = await workflow.run(
        "Saldo saya tiba-tiba berkurang Rp 500.000 tanpa transaksi yang saya kenal."
    )
    print(result.output)


if __name__ == "__main__":
    asyncio.run(main())
```

Run it:

```bash
mkdir -p .checkpoints
python apps/agent-complaint-triage/workflow.py
```

Watch the DevUI tab — you'll see three sequential agent spans, each with
its own tool/LLM calls.

:::note .NET parity
MAF .NET ships
[`CosmosCheckpointStore`](https://learn.microsoft.com/dotnet/api/microsoft.agents.ai.workflows.checkpointing)
in the `Microsoft.Agents.AI.Workflows.Checkpointing` namespace — durable
multi-day workflows backed by Cosmos DB. MAF Python core (1.3.0) ships
only `InMemoryCheckpointStorage` and `FileCheckpointStorage`. For
production-grade durability in Python you implement the
`CheckpointStorage` protocol against Cosmos yourself, or run
`FileCheckpointStorage` on a Persistent Volume.

**Recommendation:** .NET MAF + Cosmos for durable workflows;
Python MAF + file-on-PVC for shorter-lived agents.
:::

## Step 7 — Optional: Foundry Hosted Agents

Foundry Agent Service offers a managed runtime for agents — you write
the same MAF code, deploy it as a Hosted Agent, and Azure runs it in
sandboxed compute. Hosted Agents are in Public Preview and available in
Southeast Asia, East US 2, Sweden Central, and a few other regions
([region list](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agents#platform-details)).

```python
from agent_framework.foundry import FoundryChatClient, FoundryAgent
from azure.identity import DefaultAzureCredential

client = FoundryChatClient(
    project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
    model="gpt-5-mini",
    credential=DefaultAzureCredential(),
)
agent = FoundryAgent(
    project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
    agent_name="complaint-triage",
    tools=[classify_complaint],
)
```

**Hosted Agent Tracing** is also Public Preview (April 2026) — traces
from Foundry-hosted runtime show up in your Application Insights with
the rest of the workshop's OTel pipeline.

## What you just built

- A four-runtime agent that switches backends via env var, with zero
  code change.
- A three-step Workflow with checkpointing.
- A live debugger (DevUI) that visualises every tool call and agent
  hand-off.

This is the agent shape you ship to production. The platform team owns
the gateway; product teams write agents. Everyone speaks
OpenTelemetry — covered in M6.

## Reference

- [Microsoft Agent Framework docs](https://learn.microsoft.com/agent-framework/)
- [`agent-framework` on PyPI](https://pypi.org/project/agent-framework/)
- [LiteLLM](https://github.com/BerriAI/litellm)
- [Foundry Local](https://learn.microsoft.com/azure/ai-foundry/foundry-local/)
- [Hosted Agents (Preview)](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agents)

## Next

[M4.1 — Migrate from LangGraph / LangChain](./migrate-from-langgraph)
