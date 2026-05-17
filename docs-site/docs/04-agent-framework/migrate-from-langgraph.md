---
title: 4.1 — Migrate from LangGraph / LangChain
sidebar_position: 2
---

# M4.1 — LangChain → MAF: a co-opt, not a rewrite

## What you will accomplish

In this 20-minute module you will:

- Add OpenTelemetry instrumentation to an existing LangChain chain with
  three lines of code.
- Send those spans to Application Insights without touching the chain
  logic.
- Decide which agents are worth rewriting in MAF and which to leave in
  LangChain.

## The honest position

You don't have to rewrite your LangChain code. The official Microsoft
package
[`microsoft-agents-a365-observability-extensions-langchain`](https://pypi.org/project/microsoft-agents-a365-observability-extensions-langchain/)
gives you OpenTelemetry GenAI-convention spans from any LangChain chain
in three lines. Your existing agents continue to work; you just gain
gateway-grade observability for free.

## Prerequisites

- M0 Python install done (with the pinned LangChain trio).
- An `APPLICATIONINSIGHTS_CONNECTION_STRING` you can export — read it
  from your handout (`APP_INSIGHTS_CONN_STRING`):

```bash
export APPLICATIONINSIGHTS_CONNECTION_STRING="$APP_INSIGHTS_CONN_STRING"
```

## Step 1 — A LangChain chain you might already have

Create `apps/migration-langgraph-to-maf/before.py`:

```python title="apps/migration-langgraph-to-maf/before.py"
"""Pre-migration: an unmodified LangChain chain."""

import os
from langchain_openai import ChatOpenAI
from langchain.prompts import ChatPromptTemplate

llm = ChatOpenAI(
    model="gpt-5-mini",
    base_url=os.environ["APIM_URL"] + "/openai/deployments/gpt-5-mini",
    default_headers={"api-key": os.environ["APIM_KEY"]},
    default_query={"api-version": "2024-10-21"},
)

chain = (
    ChatPromptTemplate.from_template(
        "Triage this customer complaint in one short sentence: {complaint}"
    )
    | llm
)

if __name__ == "__main__":
    out = chain.invoke({"complaint": "Card not working at ATM in Surabaya"})
    print(out.content)
```

Run it:

```bash
export APIM_URL="$APIM_GATEWAY_URL"     # both from your M0 handout
# APIM_KEY is already exported

python apps/migration-langgraph-to-maf/before.py
```

You'll see a one-line response, but **no spans appear** in Application
Insights. The gateway sees the request (M2's token-metric policy
records it), but the chain itself is invisible.

## Step 2 — Add three lines of instrumentation

Copy the file to `after.py` and add the three highlighted lines:

```python title="apps/migration-langgraph-to-maf/after.py" {1-9}
from microsoft_agents_a365.observability.core import configure
from microsoft_agents_a365.observability.extensions.langchain import (
    CustomLangChainInstrumentor,
)

configure(
    service_name="complaint-triage-langchain",
    service_namespace="hybrid-ai-workshop",
)
CustomLangChainInstrumentor().instrument()

# ----- everything below is unchanged from before.py -----
import os
from langchain_openai import ChatOpenAI
from langchain.prompts import ChatPromptTemplate

llm = ChatOpenAI(
    model="gpt-5-mini",
    base_url=os.environ["APIM_URL"] + "/openai/deployments/gpt-5-mini",
    default_headers={"api-key": os.environ["APIM_KEY"]},
    default_query={"api-version": "2024-10-21"},
)

chain = (
    ChatPromptTemplate.from_template(
        "Triage this customer complaint in one short sentence: {complaint}"
    )
    | llm
)

if __name__ == "__main__":
    out = chain.invoke({"complaint": "Card not working at ATM in Surabaya"})
    print(out.content)
```

Run it:

```bash
python apps/migration-langgraph-to-maf/after.py
```

### Verify

- The terminal shows the same response as before.
- Within ~60 seconds, **Application Insights → Transaction search** has
  a new trace with `service.name=complaint-triage-langchain` and three
  spans:
  - `RunnableSequence` (root)
  - `PromptTemplate` (child)
  - `ChatOpenAI` (child with `gen_ai.*` attributes)

:::note Console exporter fallback
If you don't set `APPLICATIONINSIGHTS_CONNECTION_STRING`, A365's
`configure()` falls back to the console exporter — spans print to your
terminal as JSON. Useful for debugging without leaving your laptop.
:::

## Step 3 — Three warnings you'll see, and what they mean

When you run the instrumented chain you'll see these messages. None of
them are errors.

| Message | What it means |
| --- | --- |
| `is_agent365_exporter_enabled() not enabled or token_resolver not set. Falling back to console exporter.` | Expected when no Agent365 token is set. The Azure Monitor exporter still works. |
| `Exporter is missing a valid region.` | Add `Region=southeastasia;` to your `APPLICATIONINSIGHTS_CONNECTION_STRING` to suppress. |
| `Attempting to instrument while already instrumented` + `ExperimentalWarning` | Idempotent — re-running the script does NOT double-wrap. Cosmetic. |

The pip resolver also prints `opentelemetry-sdk 1.40.0 vs otlp-proto-grpc
1.41.1` — cosmetic, both packages co-import and run together cleanly.

## Step 4 — Same end result with MAF

If you decide to rewrite the chain in MAF, you get the agent-specific
features (typed Workflows, checkpointing, the `OpenAIChatClient` that
works against four backends). Same instrumentation pattern — different
extension:

```python
from microsoft_agents_a365.observability.core import configure
from microsoft_agents_a365.observability.extensions.agentframework import (
    AgentFrameworkInstrumentor,
)

configure(service_name="complaint-triage-maf",
          service_namespace="hybrid-ai-workshop")
AgentFrameworkInstrumentor().instrument()

# ... your MAF Agent / Workflow code
```

In the App Insights trace view, your old LangChain chain and your new
MAF agent appear as siblings — you can A/B them on the same dashboard.

## When to migrate, when to leave alone

| Capability | LangChain / LangGraph | MAF |
| --- | --- | --- |
| Existing investment | ✅ — keep using | n/a |
| Typed Workflows + checkpoint | LangGraph (Python only) | ✅ .NET CosmosCheckpointStore today; Python file-on-PVC |
| .NET parity | weak | ✅ first-class |
| One client class for AOAI / SLM / LiteLLM / Foundry Local | ❌ (different adapters per backend) | ✅ `OpenAIChatClient` everywhere |
| Native Entra / Azure auth | community packages | ✅ first-class |
| Foundry-Hosted managed runtime | n/a | ✅ one-config switch |
| Time-travel debugging | ✅ (LangGraph) | ❌ |
| LangSmith eval integration | ✅ | n/a |

**Pragmatic rule:** keep LangChain agents that work. Build new agents in
MAF. The A365 LangChain extension gives both worlds the same
observability surface.

## Verify both paths produce the same trace shape

```bash
python apps/migration-langgraph-to-maf/after.py     # LangChain
python apps/agent-complaint-triage/agent.py         # MAF
```

In **Application Insights** (Azure portal → your AI resource →
**Monitoring** → **Logs**), run:

```kusto
traces
| where timestamp > ago(10m)
| where customDimensions["service.namespace"] == "hybrid-ai-workshop"
| project timestamp, name = customDimensions["service.name"], operation_Id
| order by timestamp desc
| take 20
```

You should see traces from both `complaint-triage-langchain` and
`ComplaintTriage`. Click into each to compare the span shape — they
both follow the OpenTelemetry GenAI semantic conventions.

## What you just built

A migration recipe that:

1. Adds observability to existing LangChain agents in 3 lines.
2. Sends spans to Application Insights with the standard GenAI
   conventions.
3. Lets you migrate to MAF incrementally without flipping a switch.

## Reference

- [`microsoft-agents-a365-observability-extensions-langchain`](https://pypi.org/project/microsoft-agents-a365-observability-extensions-langchain/)
- [`microsoft-agents-a365-observability-extensions-agent-framework`](https://pypi.org/project/microsoft-agents-a365-observability-extensions-agent-framework/)
- [OpenTelemetry GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)

## Next

[M5 — Evaluation and red teaming](../evaluation-redteam/intro)
