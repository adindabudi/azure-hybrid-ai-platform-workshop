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
from importlib.metadata import version
from agent_framework.openai import OpenAIChatClient

print("agent-framework", version("agent-framework"))
print("OpenAIChatClient module", OpenAIChatClient.__module__)
PY
```

**Expected output** (the exact rc tag depends on what M0 pinned):

```
agent-framework 1.0.0rc6
OpenAIChatClient module agent_framework.openai
```

:::note 1.0.0rc6 changed where the OpenAI client lives
Until rc5 you could write `from agent_framework import OpenAIChatClient`.
From rc6 onwards the OpenAI/Azure-OpenAI clients are in the
`agent_framework.openai` subpackage (`agent-framework-openai` on PyPI),
and the old `AzureOpenAIChatClient` from `agent_framework.azure` was
removed in favor of `OpenAIChatClient` with `azure_endpoint=...`.
:::

If the import fails, revisit [M0 Step 6](../00-intro/setup.md).

## Step 2 — Walk through the agent

Open [`apps/agent-complaint-triage/agent.py`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/blob/main/apps/agent-complaint-triage/agent.py)
— the file is already in the repo from your M0 clone. The shape:

```python title="apps/agent-complaint-triage/agent.py (excerpt)"
"""Triage agent — classifies and routes customer support requests."""

import asyncio
import os

# Post-rc6: OpenAI/Azure-OpenAI clients live in agent_framework.openai.
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
    client = OpenAIChatClient(
        model=os.environ["MODEL_NAME"],
        azure_endpoint=os.environ["APIM_URL"],
        api_version="2024-10-21",
        api_key=os.environ["APIM_KEY"],
        # MODEL_TIER drives APIM's header-based routing (M1.2 Step 3).
        default_headers={"x-model-tier": os.environ.get("MODEL_TIER", "premium")},
    )

    # `client.create_agent(...)` is the convenience method that returns
    # a configured ChatAgent.
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
```

Three things to notice:

1. **Single client class** — `OpenAIChatClient` is the same class used for
   all four backends in Step 4 below. No `AzureOpenAIChatClient` /
   `LiteLLMChatClient` adapters.
2. **Tool = plain function** — `classify_complaint` is a normal Python
   function. The agent framework picks up its type hints and docstring
   to build the tool schema.
3. **`default_headers`** — sets `x-model-tier` so the workshop APIM
   policy can route between AOAI and the self-hosted SLM without any
   change to the agent code.

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

The agent code is already wired with `default_headers={"x-model-tier":
...}`, so switching backends is purely env-var work — the agent.py
binary you ran in (a) needs no code changes:

```bash
export MODEL_TIER=cheap
export MODEL_NAME=phi-4-mini-instruct
python apps/agent-complaint-triage/agent.py
```

The model output may be less polished — Phi-4-mini is a 3.8B-parameter
model — but tool calling works identically. Set `MODEL_TIER=premium`
(or unset it) to switch back to AOAI.

### (c) LiteLLM standalone

Deploy LiteLLM as a sidecar OAI-compatible proxy in your namespace
(facilitator-built image, or
[upstream](https://github.com/BerriAI/litellm)):

```bash
# Sanity-check: the secret with master-key + AOAI creds must already
# exist — facilitator seeds it via scripts/bootstrap-attendees.sh.
kubectl get secret litellm-creds -n "$NS" >/dev/null \
  && echo "litellm-creds present" \
  || echo "litellm-creds MISSING — flag facilitator before continuing"

kubectl apply -n "$NS" -f apps/litellm-comparison/deployment.yaml
kubectl rollout status deploy/litellm -n "$NS" --timeout=2m

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
use [Foundry Local](https://learn.microsoft.com/agent-framework/agents/providers/foundry-local).
This requires `agent-framework-foundry-local` (already in M0's pip
install, installed with `--pre`).

```python
from agent_framework import Agent
from agent_framework.foundry import FoundryLocalClient

agent = Agent(
    client=FoundryLocalClient(model="phi-4-mini"),
    name="ComplaintTriage",
    instructions="...",
    tools=[classify_complaint],
)
```

If you omit `model=`, set the `FOUNDRY_LOCAL_MODEL` env var. The first
run downloads the model — give it a few minutes.

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
devui apps/ --port 8080 --tracing
```

(`--tracing` is the documented flag for OTel-backed observability in
DevUI; older docs called it `--instrumentation`.)

Open [http://localhost:8080](http://localhost:8080). Pick `ComplaintTriage` from the sidebar
and send a test message. Each tool call is shown as a separate span; the
trace timeline matches what you see in Application Insights.

## Step 6 — Multi-agent Workflow

When one agent can't do the job, MAF Workflows let you connect several
into a directed graph. Use this when:

- Each step has different system prompts (triage vs. legal review).
- You need deterministic routing (always Triage → Specialist).
- You want **checkpointing** so the workflow survives a pod restart.

Open [`apps/agent-complaint-triage/workflow.py`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/blob/main/apps/agent-complaint-triage/workflow.py).
The shape:

```python title="apps/agent-complaint-triage/workflow.py (excerpt)"
from pathlib import Path

from agent_framework import FileCheckpointStorage, WorkflowBuilder
from agent_framework.openai import OpenAIChatClient
from agent_framework.orchestrations import SequentialBuilder


def _client() -> OpenAIChatClient:
    return OpenAIChatClient(
        model=os.environ["MODEL_NAME"],
        azure_endpoint=os.environ["APIM_URL"],
        api_version="2024-10-21",
        api_key=os.environ["APIM_KEY"],
        default_headers={"x-model-tier": os.environ.get("MODEL_TIER", "premium")},
    )


triage = _client().create_agent(name="Triage", instructions="Classify ...")
specialist = _client().create_agent(name="Specialist", instructions="Draft a reply ...")
compliance = _client().create_agent(name="Compliance", instructions="Redact PII ...")

# Cleanest path — three agents in a straight pipeline.
sequential = SequentialBuilder(
    participants=[triage, specialist, compliance]
).build()

# Lower-level path with checkpointing for crash recovery.
storage = FileCheckpointStorage(Path("./.checkpoints").resolve())
checkpointed = (
    WorkflowBuilder(start_executor=triage)
    .add_edge(triage, specialist)
    .add_edge(specialist, compliance)
    .with_checkpointing(storage)  # NOTE: with_checkpointing — not with_checkpoint_storage
    .build()
)
```

Run it:

```bash
mkdir -p .checkpoints
python apps/agent-complaint-triage/workflow.py                  # sequential
WORKFLOW_MODE=checkpoint python apps/agent-complaint-triage/workflow.py  # crash-resumable
```

Watch the DevUI tab — you'll see three sequential agent spans, each with
its own tool/LLM calls. With `WORKFLOW_MODE=checkpoint`, kill the process
mid-run and rerun — it picks up from the last completed step.

:::note .NET parity
MAF .NET ships
[`CosmosCheckpointStore`](https://learn.microsoft.com/dotnet/api/microsoft.agents.ai.workflows.checkpointing)
in the `Microsoft.Agents.AI.Workflows.Checkpointing` namespace — durable
multi-day workflows backed by Cosmos DB. MAF Python core (1.0.0rc6+) ships
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
from agent_framework import Agent
from agent_framework.foundry import FoundryAgent, FoundryChatClient
from azure.identity import DefaultAzureCredential

# Direct inference path — your code owns instructions + tools.
direct_agent = Agent(
    client=FoundryChatClient(
        project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        model="gpt-5-mini",
        credential=DefaultAzureCredential(),
    ),
    name="ComplaintTriage",
    instructions="You triage customer support requests.",
    tools=[classify_complaint],
)

# Service-managed path — agent definition lives in Foundry portal.
hosted_agent = FoundryAgent(
    project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
    agent_name="complaint-triage",
    agent_version="1.0",
    credential=DefaultAzureCredential(),
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
