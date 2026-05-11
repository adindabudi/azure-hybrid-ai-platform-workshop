# eval-suite

Reproducible eval and red-teaming pipeline for the M4 agent. Used in
**M5 — Evaluation and red teaming**.

| File | Purpose |
| --- | --- |
| `run_foundry_evals.py` | 5 Foundry-style evaluators (`azure-ai-evaluation`) over a seeded JSONL fixture |
| `redteam.py` | AI Red Teaming Agent (`azure-ai-evaluation[redteam]`) — 4 risk categories × 2 attack strategies |
| `requirements.txt` | Pinned versions used by the GitHub Actions eval gate |
| `eval-gate.yml.example` | Example workflow you copy to `.github/workflows/eval.yml` in your fork |

## Run locally

```bash
source .venv/bin/activate
pip install -r apps/eval-suite/requirements.txt

export APIM_URL="$APIM_GATEWAY_URL"
python apps/eval-suite/run_foundry_evals.py    # writes apps/eval-suite/eval-results.json
python apps/eval-suite/redteam.py              # writes apps/eval-suite/redteam-results.json
```

## Wire into PRs

Copy [`eval-gate.yml.example`](./eval-gate.yml.example) to
`.github/workflows/eval.yml` in your fork and add three repository
secrets:

- `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` —
  workload identity for `azure/login@v2`
- `APIM_URL`, `APIM_KEY` — gateway credentials

The job blocks the PR when `intent_resolution < 0.80` or
`tool_call_accuracy < 0.75`.

## Choosing between evaluators

See M5 Step 1 for the full table — short version:

- Tool-calling agents → **MAF / Foundry** (this dir)
- RAG quality → **Ragas**
- Fast unit-test style checks → **DeepEval**
- Latency / regex / schema → hand-rolled Python
