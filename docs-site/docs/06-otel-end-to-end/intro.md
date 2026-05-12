---
title: 6.0 — OpenTelemetry end-to-end
sidebar_position: 1
---

# M6 — One trace, user click → model response

## What you will accomplish

In this 45-minute module you will:

- Enable OpenTelemetry instrumentation in the MAF agent.
- Send spans to Application Insights AND to a parallel OTLP collector.
- Read one complete trace from gateway → agent → MCP tool → model.
- Run the **Aspire Dashboard** locally for the no-internet path.

## How the trace flows

```
laptop  →  APIM   →  Agent pod    →  MCP server   →  LLM backend
  │         │           │                │                │
  └── client span       └── agent span   └── tool span    └── llm span
              \                 │                │
               \                ▼                ▼
                \────────► Application Insights (also OTLP-compatible)
                 \
                  └──► OTLP collector (optional)
                            │
                            ▼
                       Aspire Dashboard / Grafana Tempo / Datadog / Splunk
```

Every hop emits a span with the same `trace_id`. App Insights stitches
them into one transaction.

## Prerequisites

- M4 done — you have a working MAF agent.
- M0 Python install — `microsoft-agents-a365-observability-extensions-agent-framework`
  and `azure-monitor-opentelemetry` are installed.
- The connection string for the workshop App Insights — from your M0
  handout (`APP_INSIGHTS_CONN_STRING`):

```bash
export APPLICATIONINSIGHTS_CONNECTION_STRING="$APP_INSIGHTS_CONN_STRING"
```

The string has the form
`InstrumentationKey=...;IngestionEndpoint=...;Region=...`.

## Step 1 — Instrument the agent

Add the highlighted lines to the **top** of
`apps/agent-complaint-triage/agent.py`:

```python {1-12}
from azure.monitor.opentelemetry import configure_azure_monitor
from microsoft_agents_a365.observability.core import configure
from microsoft_agents_a365.observability.extensions.agentframework import (
    AgentFrameworkInstrumentor,
)

configure(
    service_name="ComplaintTriage",
    service_namespace="hybrid-ai-workshop",
)
# Send the configured spans to App Insights via the Azure Monitor distro.
# Reads APPLICATIONINSIGHTS_CONNECTION_STRING from the environment.
configure_azure_monitor()
AgentFrameworkInstrumentor().instrument()

# ----- everything below is unchanged -----
import asyncio
import os
from agent_framework.openai import OpenAIChatClient
...
```

Run it:

```bash
python apps/agent-complaint-triage/agent.py
```

Within ~60 seconds, **Application Insights → Transaction search** shows
a new trace with two spans:

- `ChatAgent.run` (root) — your agent
- `chat.completions.create` (child) — the LLM call with full
  `gen_ai.*` semantic-convention attributes

If you also have a tool call (`classify_complaint`), it appears as a
third span.

:::caution PII risk
Set `AZURE_TRACING_GEN_AI_CONTENT_RECORDING_ENABLED=true` only in dev.
With it on, the full prompt and completion are captured as span
attributes — useful for debugging, dangerous for PII.
:::

## Step 2 — Add a parallel OTLP collector

App Insights is one backend. For an apples-to-apples comparison with
on-prem stacks, also export to OTLP.

Spin up a local Aspire Dashboard (Microsoft's OTLP visualizer):

```bash
docker run --rm -d \
  --name aspire-dashboard \
  -p 18888:18888 -p 18889:18889 \
  -e DOTNET_DASHBOARD_UNSECURED_ALLOW_ANONYMOUS=true \
  mcr.microsoft.com/dotnet/aspire-dashboard:latest
```

Open [http://localhost:18888](http://localhost:18888) — empty for now.

Update the agent to dual-export. Replace the M6 Step 1 instrumentation
block with:

```python
from azure.monitor.opentelemetry import configure_azure_monitor
from microsoft_agents_a365.observability.core import configure
from microsoft_agents_a365.observability.extensions.agentframework import (
    AgentFrameworkInstrumentor,
)
from opentelemetry import trace
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import (
    OTLPSpanExporter,
)

configure(
    service_name="ComplaintTriage",
    service_namespace="hybrid-ai-workshop",
)
configure_azure_monitor()       # Application Insights export

# Add OTLP export alongside the App Insights exporter.
trace.get_tracer_provider().add_span_processor(
    BatchSpanProcessor(OTLPSpanExporter(
        endpoint="http://localhost:18889",
        insecure=True,
    ))
)

AgentFrameworkInstrumentor().instrument()
```

Run the agent again. The trace appears in **both** App Insights *and*
the Aspire Dashboard.

## Step 3 — Walk through one full trace

Send a complaint that triggers all three components — agent + tool +
LLM — through the workshop gateway:

```bash
curl -sS \
  "${APIM_GATEWAY_URL}/openai/deployments/gpt-5-mini/chat/completions?api-version=2024-10-21" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
  -H "Content-Type: application/json" \
  -H "x-trace-from: workshop" \
  -d '{"messages":[{"role":"user","content":"My card was swallowed at the ATM."}]}' \
  -o /dev/null
```

In **Application Insights → Transaction search**, filter by
`x-trace-from: workshop` to find your trace. You should see:

```
APIM gateway request   200 ms
└── llm-token-limit policy           1 ms
└── llm-semantic-cache-lookup        15 ms
└── llm-emit-token-metric            0 ms
└── backend: aoai-sea/openai/...    180 ms
```

If your agent script triggered the request, you'll see an additional
parent transaction with `service.name=ComplaintTriage` joined by
`trace_id`.

## Step 4 — KQL: per-tool p95 latency

A useful dashboard query for the platform team. Run it in
**Application Insights** → **Monitoring** → **Logs** (Azure portal):

```kusto
dependencies
| where timestamp > ago(1h)
| where customDimensions["gen_ai.operation.name"] != ""
| extend
    op   = tostring(customDimensions["gen_ai.operation.name"]),
    model = tostring(customDimensions["gen_ai.request.model"])
| summarize
    count = count(),
    p50 = percentile(duration, 50),
    p95 = percentile(duration, 95),
    p99 = percentile(duration, 99)
    by op, model
| order by p95 desc
```

**Expected output** — one row per `(operation, model)` with latency
percentiles.

## Step 5 — Three benign warnings (talk-track them)

| Message | Meaning |
| --- | --- |
| `is_agent365_exporter_enabled() not enabled or token_resolver not set. Falling back to console exporter.` | Expected when you have no Agent365 token. App Insights export still works. |
| `Exporter is missing a valid region.` | Add `Region=southeastasia;` to your `APPLICATIONINSIGHTS_CONNECTION_STRING` to suppress. |
| `Attempting to instrument while already instrumented` + `ExperimentalWarning` | Idempotent. Cosmetic. Re-running the script does NOT double-wrap. |

The `opentelemetry-sdk 1.40.0 vs otlp-proto-grpc 1.41.1` pip resolver
warning is also cosmetic — both packages co-import and run together
cleanly.

## Step 6 — Vendor-neutrality

OpenTelemetry is open standard, not a Microsoft format. The same
`OTLPSpanExporter` works against:

- [Grafana Tempo](https://grafana.com/oss/tempo/)
- [Jaeger](https://www.jaegertracing.io/)
- [Datadog APM](https://docs.datadoghq.com/tracing/)
- [Splunk APM](https://docs.splunk.com/observability/en/apm/)
- [New Relic](https://docs.newrelic.com/docs/opentelemetry/)
- Elastic, Honeycomb, Lightstep, etc.

To switch destinations: change the endpoint URL on the
`OTLPSpanExporter`. No agent code changes.

## What you just built

- A trace that connects user request → gateway policy → agent →
  tool → LLM, all under one `trace_id`.
- A dashboard query that shows per-tool latency percentiles.
- A vendor-neutral OTLP path that can target Aspire today and Splunk
  tomorrow.

## Reference

- [Azure Monitor OpenTelemetry distro](https://learn.microsoft.com/azure/azure-monitor/app/opentelemetry-enable)
- [OpenTelemetry GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
- [Aspire Dashboard standalone mode](https://learn.microsoft.com/dotnet/aspire/fundamentals/dashboard/standalone)

## Next

[Wrap-up](../wrap-up)
