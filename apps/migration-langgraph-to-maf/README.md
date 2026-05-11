# migration-langgraph-to-maf

Demonstrates the **3-line** path from a vanilla LangChain chain to one
that emits OpenTelemetry GenAI-convention spans into Application
Insights — without rewriting the chain.

Used in **M4.1 — Migrate from LangGraph / LangChain**.

| File | What it shows |
| --- | --- |
| `before.py` | Plain LangChain chain. Calls APIM gpt-5-mini, no spans. |
| `after.py` | Same chain + 3-line A365 instrumentation. Spans land in App Insights. |

## Run

```bash
source .venv/bin/activate                  # M0 venv (LangChain trio pinned)
export APIM_URL="$APIM_GATEWAY_URL"        # from your M0 handout
export APPLICATIONINSIGHTS_CONNECTION_STRING="$APP_INSIGHTS_CONN_STRING"

python apps/migration-langgraph-to-maf/before.py    # baseline
python apps/migration-langgraph-to-maf/after.py     # instrumented
```

Within ~60 s the second run shows up in **Application Insights →
Transaction search** as `service.name=complaint-triage-langchain`
with three spans (`RunnableSequence` → `PromptTemplate` → `ChatOpenAI`).

## When to migrate, when to leave alone

See the table at the bottom of
[`docs/04-agent-framework/migrate-from-langgraph.md`](../../docs-site/docs/04-agent-framework/migrate-from-langgraph.md).

Pragmatic rule: keep LangChain agents that work; build new agents in
MAF; the A365 LangChain extension gives both worlds the same
observability surface.
