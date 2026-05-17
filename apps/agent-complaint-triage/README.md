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
| Foundry Local | swap `OpenAIChatCompletionClient` for `FoundryLocalClient` — see M4 Step 4(d) |

## Why `OpenAIChatCompletionClient` (and not `OpenAIChatClient`)?

`agent-framework` 1.4.0 split the OpenAI client surface in two:

- **`OpenAIChatClient`** → calls the **OpenAI Responses API**
  (`/v1/responses`). Azure OpenAI exposes it, but the APIM Developer
  SKU in this workshop imports the `inference.json` spec from
  `Azure/azure-rest-api-specs`, which only includes
  `/openai/deployments/{name}/chat/completions`. Requests to
  `/responses` 404 at the gateway.
- **`OpenAIChatCompletionClient`** → calls the **chat completions API**,
  which is what APIM exposes today. Use this whenever APIM sits in
  front of AOAI (which is always in this workshop).

If you're pointing the agent directly at Azure OpenAI without APIM in
front, either client works — Responses API gives you slightly better
streaming. The workshop sticks with `OpenAIChatCompletionClient` for
consistency.
