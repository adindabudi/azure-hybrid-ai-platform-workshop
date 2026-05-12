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
export APIM_URL="$APIM_GATEWAY_URL"
export MODEL_NAME=gpt-5-mini
# APIM_KEY already exported from M0.
```

## Step 1 — A LangChain agent you might already have

The "before" state is a LangChain `AgentExecutor` with **hand-rolled
OpenTelemetry**: one tracer, one span per tool call, one outer span
around the agent invocation. The file lives at
[`apps/migration-langgraph-to-maf/before.py`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/blob/main/apps/migration-langgraph-to-maf/before.py)
and looks like this (excerpt):

```python title="apps/migration-langgraph-to-maf/before.py (excerpt)"
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter

trace.set_tracer_provider(TracerProvider())
trace.get_tracer_provider().add_span_processor(
    BatchSpanProcessor(ConsoleSpanExporter())
)
tracer = trace.get_tracer("complaint-triage-langchain-before")


@tool
def classify_complaint(text: str) -> dict:
    # Manual span for every tool call — boilerplate that grows linearly
    # with the number of tools you add.
    with tracer.start_as_current_span("tool.classify_complaint") as span:
        span.set_attribute("input.length", len(text))
        ...


async def main() -> None:
    agent = build_agent()
    # Manual outer span around the agent invocation.
    with tracer.start_as_current_span("agent.run") as span:
        span.set_attribute("genai.system", "azure_openai_via_apim")
        span.set_attribute("genai.request.model", os.environ["MODEL_NAME"])
        result = await agent.ainvoke({"input": "..."})
```

Run it:

```bash
python apps/migration-langgraph-to-maf/before.py
```

You'll see the response, plus the manual spans printed to the console by
`ConsoleSpanExporter`. The pain points: every new tool needs another
`with tracer.start_as_current_span(...)` block, and the attribute names
(`genai.system`, `genai.request.model`) are whatever your team decided
— there's no shared schema with Foundry or App Insights.

## Step 2 — Three lines, full GenAI semantic-convention spans

Compare against
[`apps/migration-langgraph-to-maf/after.py`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/blob/main/apps/migration-langgraph-to-maf/after.py).
The manual OTel boilerplate (provider, exporter, every per-tool span)
is replaced with three lines from the Microsoft Agents 365 extension:

```python title="apps/migration-langgraph-to-maf/after.py (excerpt)"
from microsoft_agents_a365.observability.core import configure
from microsoft_agents_a365.observability.extensions.langchain import (
    CustomLangChainInstrumentor,
)

configure(
    service_name="complaint-triage-langchain",
    service_namespace="hybrid-ai-workshop",
)
CustomLangChainInstrumentor().instrument()


@tool
def classify_complaint(text: str) -> dict:
    # No manual span — the instrumentor wraps every @tool automatically
    # and emits OTel GenAI semantic-convention attributes.
    ...
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
  - `AgentExecutor.ainvoke` (root)
  - `ChatOpenAI` (child with `gen_ai.*` attributes)
  - `tool.classify_complaint` (child, auto-wrapped)

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
