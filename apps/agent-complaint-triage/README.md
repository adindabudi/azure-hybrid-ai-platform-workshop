# agent-complaint-triage

Reference Microsoft Agent Framework agent used in **M4 — Agent Framework**.

| File | What it shows |
| --- | --- |
| `agent.py` | Single agent with one Python tool — runs against APIM/AOAI, APIM/SLM, LiteLLM, or Foundry Local by changing env vars |
| `workflow.py` | 3-step Workflow (Triage → Specialist → Compliance) with file-based checkpoint storage |

## Setup

```bash
source .venv/bin/activate                  # M0 Step 6 venv
export APIM_URL="$APIM_GATEWAY_URL"        # from your M0 handout
export MODEL_NAME=gpt-5-mini
```

## Run the agent

```bash
python apps/agent-complaint-triage/agent.py
```

## Run the workflow with checkpointing

```bash
mkdir -p .checkpoints
python apps/agent-complaint-triage/workflow.py
ls -lh .checkpoints/                       # one JSON per executor hop
```

## Switch backends

| Backend | env vars |
| --- | --- |
| APIM → AOAI Singapore | `MODEL_TIER=premium MODEL_NAME=gpt-5-mini` |
| APIM → self-hosted Phi-4-mini | `MODEL_TIER=cheap MODEL_NAME=phi-4-mini-instruct` |
| LiteLLM standalone | `APIM_URL=http://<litellm-svc>:4000 MODEL_NAME=gpt-5-mini-via-litellm` |
| Foundry Local | swap `OpenAIChatClient` for `FoundryLocalClient` — see M4 Step 4(d) |
