---
title: 5.0 — Evaluation and red teaming
sidebar_position: 1
---

# M5 — Reproducible evaluation, gated on PR

## What you will accomplish

In this 45-minute module you will:

- Run the **MAF / Foundry built-in evaluators** against the M4 agent.
- Compare results across **DeepEval**, **Ragas**, and a hand-rolled
  Python script, and learn when to pick each.
- Wire evaluation into a **GitHub Actions** check that fails the PR on
  regression.
- Run the **AI Red Teaming Agent** in local PyRIT mode, and understand
  which categories are *not* reachable outside specific regions.

## Prerequisites

- M4 done — you have a working agent that responds to chat completions.
- ~5 USD of LLM-judge budget for the eval pass (M5 makes ~50 judge
  calls).

## Step 1 — Pick the right evaluator

Run the same test set through each option and compare. You don't have
time for all five in one workshop — pick the right one for the question
you're answering.

| Tool | Best for | Has agent-specific metrics? | Cost per run |
| --- | --- | --- | --- |
| **MAF / Foundry Evaluators** | Tool-call accuracy, intent resolution, task adherence, safety | ✅ | LLM-judge fees |
| **DeepEval** | G-Eval, unit-test style assertions, custom metrics | ⚠️ partial | LLM-judge fees |
| **Ragas** | RAG faithfulness, answer-relevance, context-precision | ❌ (RAG only) | LLM-judge fees |
| **LangSmith eval** | Mature, integrated with LangChain | ⚠️ partial | SaaS subscription |
| **Hand-rolled Python** | Latency, regex match, schema check | ❌ | $0 |

**Decision rule:**

- Tool-calling agents → MAF/Foundry.
- RAG quality → Ragas.
- Fast unit-test style checks → DeepEval.
- Latency / exact match / schema → hand-rolled.

## Step 2 — Run Foundry evaluators on the M4 agent

Create `apps/eval-suite/run_foundry_evals.py`:

```python title="apps/eval-suite/run_foundry_evals.py"
"""Run the Foundry agent-specific evaluators against the M4 agent."""

import os
from agent_framework.foundry import (
    evaluate_foundry_target, evaluate_traces,
)


TEST_QUERIES = [
    "Card not working at the ATM in Surabaya — what should I do?",
    "Saya lupa password mobile banking, bagaimana cara reset?",
    "Show me last month's statement.",
    "Transfer Rp 50.000.000 to account 1234567890 right now.",
    "Why did you charge me an extra fee yesterday?",
]


def main():
    results = evaluate_foundry_target(
        # The agent is reachable through the APIM gateway as if it were
        # a chat completion. Foundry sends test_queries through the same
        # /chat/completions endpoint your callers use.
        target={
            "endpoint": os.environ["APIM_URL"],
            "model": "gpt-5-mini",
            "api_key": os.environ["APIM_KEY"],
        },
        test_queries=TEST_QUERIES,
        evaluators=[
            "groundedness",
            "relevance",
            "intent_resolution",
            "tool_call_accuracy",
            "task_adherence",
        ],
        # The judge model. Workshop reuses APIM gpt-5-mini; production
        # may want a stronger judge model.
        model="gpt-5-mini",
    )

    print(results.summary())
    results.to_jsonl("eval-results.jsonl")


if __name__ == "__main__":
    main()
```

Run it:

```bash
python apps/eval-suite/run_foundry_evals.py
```

**Expected output** — a summary table similar to:

```
metric                  mean   p50   p10
groundedness            0.92   1.00  0.80
relevance               0.88   1.00  0.60
intent_resolution       0.95   1.00  0.80
tool_call_accuracy      0.81   1.00  0.50
task_adherence          0.86   1.00  0.60
```

Each test_query produced one row per evaluator in `eval-results.jsonl`.

## Step 3 — Gate the PR with GitHub Actions

Add `.github/workflows/eval.yml`:

```yaml title=".github/workflows/eval.yml"
name: AI eval gate

on:
  pull_request:
    paths:
      - "apps/agent-complaint-triage/**"
      - "apps/eval-suite/**"

jobs:
  eval:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.13" }
      - run: |
          python -m pip install --upgrade pip
          pip install -r apps/eval-suite/requirements.txt
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - run: |
          export APIM_URL="${{ secrets.APIM_URL }}"
          export APIM_KEY="${{ secrets.APIM_KEY }}"
          python apps/eval-suite/run_foundry_evals.py
      - name: Enforce thresholds
        run: |
          python - <<'PY'
          import json, sys
          rows = [json.loads(l) for l in open("eval-results.jsonl")]
          ir = sum(r["intent_resolution"] for r in rows) / len(rows)
          tc = sum(r["tool_call_accuracy"] for r in rows) / len(rows)
          ok = ir >= 0.80 and tc >= 0.75
          print(f"intent_resolution={ir:.2f}  tool_call_accuracy={tc:.2f}")
          sys.exit(0 if ok else 1)
          PY
```

Connect to Azure with workload identity per
[the docs](https://learn.microsoft.com/azure/developer/github/connect-from-azure).

## Step 4 — Red team with PyRIT (local mode)

The [AI Red Teaming Agent](https://learn.microsoft.com/azure/foundry/concepts/ai-red-teaming-agent)
has two modes: cloud and local. **Cloud mode** is available in East US 2,
France Central, Sweden Central, Switzerland West, and US North Central
only — for regions outside that list you must use local mode.

```bash
pip install azure-ai-red-teaming pyrit

cat > apps/eval-suite/redteam.py <<'PY'
import asyncio
from azure.ai.red_teaming import RedTeamingAgent, RiskCategory, AttackStrategy
import os

agent = RedTeamingAgent(
    target_endpoint=os.environ["APIM_URL"],
    target_model="gpt-5-mini",
    target_api_key=os.environ["APIM_KEY"],
    mode="local",
)

async def main():
    report = await agent.scan(
        risk_categories=[
            RiskCategory.Violence,
            RiskCategory.HateUnfairness,
            RiskCategory.Sexual,
            RiskCategory.SelfHarm,
            RiskCategory.ProtectedMaterial,
            RiskCategory.CodeVulnerability,
        ],
        attack_strategies=[
            AttackStrategy.Jailbreak,
            AttackStrategy.Crescendo,
            AttackStrategy.UnicodeConfusable,
        ],
    )
    print(report.summary())
    report.save("redteam-scorecard.html")

asyncio.run(main())
PY

python apps/eval-suite/redteam.py
```

Open `redteam-scorecard.html` in a browser — it shows pass/fail per
risk category and per attack strategy with example prompts.

## Step 5 — Known limitations

Be aware of these gaps before you rely on the Foundry red-teaming
agent as your only safety net:

- **Agent-specific risk categories** — *Prohibited Actions*,
  *Sensitive Data Leakage*, *Task Adherence* — are **cloud-only**, and
  cloud mode runs only in five regions
  ([source](https://learn.microsoft.com/azure/foundry/concepts/ai-red-teaming-agent#agentic-risks)).
- Both modes are **single-turn**, **English-only**, and use **synthetic
  test data**.

If you need multi-turn red teaming in a non-English language, or you
need the agent-specific categories without sending traffic outside your
region, layer these on top:

1. Design-time threat modeling (handout in M3).
2. APIM content-safety guardrails (M2).
3. Manual review of multi-turn agent traces in Application Insights.
4. A custom adversarial test set in the target language, fed into
   DeepEval or the hand-rolled script.

## What you just built

- An automated eval pass scoring five agent-specific metrics.
- A PR gate that blocks regressions in `intent_resolution` and
  `tool_call_accuracy`.
- A local red-team scan covering 6 risk categories × 3 attack
  strategies.

## Reference

- [Foundry evaluators](https://learn.microsoft.com/azure/foundry/concepts/evaluation-evaluators/agent-evaluators)
- [AI Red Teaming Agent](https://learn.microsoft.com/azure/foundry/concepts/ai-red-teaming-agent)
- [`pyrit`](https://github.com/Azure/PyRIT)
- [DeepEval](https://github.com/confident-ai/deepeval)
- [Ragas](https://github.com/explodinggradients/ragas)

## Next

[M6 — OpenTelemetry end-to-end](../otel-end-to-end/intro)
