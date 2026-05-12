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

## Step 2 — Run Foundry-style evaluators on the M4 agent

The Microsoft `azure-ai-evaluation` SDK ships the same LLM-judge
evaluators that Azure AI Foundry uses in its portal — you can run them
locally without creating a Foundry project. The workshop file lives at
[`apps/eval-suite/run_foundry_evals.py`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/blob/main/apps/eval-suite/run_foundry_evals.py)
and is already in your M0 clone. The shape:

```python title="apps/eval-suite/run_foundry_evals.py (excerpt)"
"""Run the Foundry-style evaluators against the M4 agent."""

import os
from pathlib import Path

from azure.ai.evaluation import (
    GroundednessEvaluator,
    IntentResolutionEvaluator,
    RelevanceEvaluator,
    TaskAdherenceEvaluator,
    ToolCallAccuracyEvaluator,
    evaluate,
)

HERE = Path(__file__).parent
DATA = HERE / "test_data.jsonl"        # see repo for fixture
OUTPUT = HERE / "eval-results.json"

# Judge-model config. Workshop reuses the APIM-fronted gpt-5-mini;
# production may want a stronger judge such as gpt-4.1 or o3-mini.
model_config = {
    "azure_endpoint": os.environ["APIM_URL"],
    "api_key": os.environ["APIM_KEY"],
    "azure_deployment": os.environ.get("JUDGE_MODEL", "gpt-5-mini"),
    "api_version": "2024-10-21",
}

result = evaluate(
    data=str(DATA),
    evaluators={
        "intent_resolution": IntentResolutionEvaluator(model_config=model_config),
        "tool_call_accuracy": ToolCallAccuracyEvaluator(model_config=model_config),
        "task_adherence": TaskAdherenceEvaluator(model_config=model_config),
        "relevance": RelevanceEvaluator(model_config=model_config),
        "groundedness": GroundednessEvaluator(model_config=model_config),
    },
    output_path=str(OUTPUT),
)

for name, value in sorted(result["metrics"].items()):
    print(f"{name}: {value}")
```

The repo file additionally seeds a tiny three-row JSONL fixture and
enforces an `EVAL_PASS_THRESHOLD` gate (default 0.7) — useful when this
is run from CI.

Run it:

```bash
python apps/eval-suite/run_foundry_evals.py
```

**Expected output** — pass-rate metrics similar to:

```
groundedness.pass_rate: 0.92
intent_resolution.pass_rate: 0.95
relevance.pass_rate: 0.88
task_adherence.pass_rate: 0.86
tool_call_accuracy.pass_rate: 0.81
```

Full per-row scores land in `eval-results.json`.

:::note Why not `agent_framework_azure_ai.FoundryEvals`?
[`FoundryEvals`](https://learn.microsoft.com/agent-framework/agents/evaluation#azure-ai-foundry-evaluators)
from `agent-framework-azure-ai` is a thin wrapper around the same
evaluator set, but it requires a Foundry project endpoint to upload
results. We use the standalone `azure-ai-evaluation` SDK so the
workshop runs anywhere.
:::

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
          report = json.load(open("apps/eval-suite/eval-results.json"))
          metrics = report["metrics"]
          ir = metrics["intent_resolution.pass_rate"]
          tc = metrics["tool_call_accuracy.pass_rate"]
          ok = ir >= 0.80 and tc >= 0.75
          print(f"intent_resolution={ir:.2f}  tool_call_accuracy={tc:.2f}")
          sys.exit(0 if ok else 1)
          PY
```

Connect to Azure with workload identity per
[the docs](https://learn.microsoft.com/azure/developer/github/connect-from-azure).

## Step 4 — Red team with PyRIT (local mode)

The [AI Red Teaming Agent](https://learn.microsoft.com/azure/ai-foundry/concepts/ai-red-teaming-agent)
ships in the `[redteam]` extra of `azure-ai-evaluation` and is built on
[PyRIT](https://github.com/Azure/PyRIT). It has two modes: cloud and
local. **Cloud mode** is available in East US 2, France Central, Sweden
Central, Switzerland West, and US North Central only — for regions
outside that list you must use local mode.

The workshop file
[`apps/eval-suite/redteam.py`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/blob/main/apps/eval-suite/redteam.py)
ships **two run modes** (callback against the M4 agent, or model-direct
against APIM) and an attack-success-rate gate. The skeleton:

```python title="apps/eval-suite/redteam.py (excerpt)"
from azure.ai.evaluation.red_team import (
    AttackStrategy,
    RedTeam,
    RiskCategory,
)
from azure.identity import DefaultAzureCredential


async def agent_callback(query: str) -> str:
    """Adapter the scanner calls per attack prompt."""
    from agent import build_agent  # apps/agent-complaint-triage/agent.py
    response = await build_agent().run(query)
    return response.text


async def main():
    red_team = RedTeam(
        # azure_ai_project is required by the constructor; only used for
        # cloud scans. Leaving subscription_id="" keeps us in local mode.
        azure_ai_project={"subscription_id": "", "resource_group_name": "", "project_name": ""},
        credential=DefaultAzureCredential(),
        risk_categories=[
            RiskCategory.Violence,
            RiskCategory.HateUnfairness,
            RiskCategory.SelfHarm,
            RiskCategory.Sexual,
        ],
        num_objectives=int(os.environ.get("REDTEAM_OBJECTIVES", "5")),
    )
    await red_team.scan(
        target=agent_callback,
        attack_strategies=[AttackStrategy.EASY, AttackStrategy.MODERATE],
        output_path="redteam-results.json",
    )
```

Run it (install the `[redteam]` extra once if you haven't already):

```bash
pip install "azure-ai-evaluation[redteam]" azure-identity azure-ai-projects

python apps/eval-suite/redteam.py
```

Set `REDTEAM_MODE=model` to scan the underlying model directly (raw
model safety without the agent guardrails). `REDTEAM_ASR_CEILING`
controls the pass/fail gate — default 10%.

Open `redteam-results.json` — it contains attack-success-rate per risk
category and per attack strategy with the offending prompts and
responses.

## Step 5 — Known limitations

Be aware of these gaps before you rely on the Foundry red-teaming
agent as your only safety net:

- **Agent-specific risk categories** — *Prohibited Actions*,
  *Sensitive Data Leakage*, *Task Adherence* — are **cloud-only**, and
  cloud mode runs only in five regions
  ([source](https://learn.microsoft.com/azure/ai-foundry/concepts/ai-red-teaming-agent)).
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

- [Foundry evaluators](https://learn.microsoft.com/azure/ai-foundry/concepts/evaluation-evaluators/agent-evaluators)
- [AI Red Teaming Agent](https://learn.microsoft.com/azure/ai-foundry/concepts/ai-red-teaming-agent)
- [`azure-ai-evaluation` Python SDK](https://learn.microsoft.com/python/api/azure-ai-evaluation/)
- [`pyrit`](https://github.com/Azure/PyRIT)
- [DeepEval](https://github.com/confident-ai/deepeval)
- [Ragas](https://github.com/explodinggradients/ragas)

## Next

[M6 — OpenTelemetry end-to-end](../otel-end-to-end/intro)
