# `apps/slm-phi4-cpu/` — self-hosted Phi-4-mini SLM for the cheap routing branch

Opt-in deployment that wires up the **`slm-phi4`** Kubernetes service that
`scripts/apply-apim-policies.sh` (and the APIM `load-balancer-priority.xml` +
`workshop-llm-policy.xml` header-routing policies) already expect.

## What it gives you

| Without this deployment | With this deployment |
|-------------------------|----------------------|
| APIM `slm-phi4` backend skipped or points at `http://10.224.0.1:8000/v1` placeholder | APIM backend `slm-phi4` registered with the real internal LB IP |
| `x-model-tier: cheap` requests return 5xx | `x-model-tier: cheap` requests return `phi4-mini:3.8b` JSON |
| `verify-policies.sh` Step 6 yellow-skips with "SLM not deployed" | `verify-policies.sh` Step 6 turns green |
| `load-balancer-priority.xml` failover demo is hypothetical | Failover demo actually flips from `aoai-sea` (P1) to `slm-phi4` (P2) when AOAI is unhealthy |

## What's inside

- **Namespace `slm`** — matches what
  `scripts/apply-apim-policies.sh` greps for (`kubectl get svc slm-phi4 -n slm`)
- **PVC `slm-phi4-models` (10 Gi)** — caches the ~2.5 GB GGUF blob so pod
  restarts don't re-pull
- **Deployment `slm-phi4`** —
  [`ollama/ollama:0.5.13`](https://github.com/ollama/ollama/releases/tag/v0.5.13)
  (minimum version that supports Phi-4-mini per the
  [model card](https://ollama.com/library/phi4-mini)):
  - `initContainer ollama-warm-model` pre-pulls `phi4-mini:3.8b` so the first
    user request doesn't time out waiting on a ~3 min download
  - Main container binds `OLLAMA_HOST=0.0.0.0:8000` so the Service URL stays
    `http://${IP}:8000/v1` (matches the APIM backend definition)
  - `OLLAMA_KEEP_ALIVE=1h` keeps the model resident between APIM bursts
  - `OLLAMA_NUM_PARALLEL=1` to prevent CPU thrash on shared workshop nodes
- **Service `slm-phi4`** — `type: LoadBalancer` with
  `service.beta.kubernetes.io/azure-load-balancer-internal: "true"` →
  APIM reaches it over the VNet, not the public internet

## Resource expectations

Phi-4-mini-instruct (3.8 B params, Q4_K_M GGUF quantization) on CPU:

| Resource | Tested OK |
|----------|-----------|
| CPU (request / limit) | 2 / 4 cores |
| Memory (request / limit) | 6 Gi / 8 Gi |
| First-pull time | ~3 min (initContainer) |
| Cold first-token | ~10 s |
| Steady-state tokens/sec | ~8-15 tok/s (Standard_D4s_v5 / AVX2; faster on AVX-512) |

If your node pool is small (e.g. one `Standard_D4s_v5` per attendee), schedule
this Deployment on a dedicated node and avoid co-tenanting with other heavy
pods. For the workshop, attendees share the cluster, so **only the facilitator
deploys this once** in the shared `slm` namespace.

## Deploy

```bash
kubectl apply -f apps/slm-phi4-cpu/deployment.yaml

# Watch the initContainer pull the model (~3 min on a clean cluster):
kubectl logs -f deployment/slm-phi4 -n slm -c ollama-warm-model

# Wait for the internal LB to assign an IP (~1 min):
kubectl get svc slm-phi4 -n slm -w
# NAME       TYPE           CLUSTER-IP    EXTERNAL-IP   PORT(S)
# slm-phi4   LoadBalancer   10.0.123.45   10.224.0.42   8000:30123/TCP
```

Then re-run the policy applier so APIM picks up the real backend IP:

```bash
./scripts/apply-apim-policies.sh
```

`apply-apim-policies.sh` Step 3 will now log
`Backend slm-phi4 (http://10.224.0.42:8000/v1)` instead of yellow-skipping.

## Verify

```bash
export APIM_GATEWAY_URL=$(terraform -chdir=infra output -raw apim_gateway_url)
export APIM_KEY=$(az apim subscription show \
  -g $(terraform -chdir=infra output -raw resource_group_name) \
  --service-name $(terraform -chdir=infra output -raw apim_name) \
  --sid attendee-01 --query primaryKey -o tsv)

curl -sS -X POST "${APIM_GATEWAY_URL}/openai/deployments/gpt-5-mini/chat/completions?api-version=2024-10-21" \
  -H "api-key: ${APIM_KEY}" \
  -H "x-auth-mode: anonymous" \
  -H "x-model-tier: cheap" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"In one sentence: what is Kubernetes?"}]}' \
  | jq -r '.model, .choices[0].message.content'
# phi4-mini:3.8b
# Kubernetes is an open-source container orchestration platform...
```

Or just re-run the workshop verifier — Step 6 should flip to green:

```bash
./scripts/verify-policies.sh
# ✓ Step 6 — header routing: premium → 'gpt-5-mini-2025-08-07'; cheap → 'phi4-mini:3.8b'
```

## Tear down

```bash
kubectl delete -f apps/slm-phi4-cpu/deployment.yaml
# The PVC is in the manifest, so this reclaims the 10 Gi disk too.
```

## Why Ollama (not vLLM / TGI)?

| Option | Why we didn't pick it |
|--------|-----------------------|
| `vllm/vllm-openai:latest` | No officially published CPU-only image; CPU build requires building from source |
| `ghcr.io/huggingface/text-generation-inference:cpu` | Phi-4-mini not in the supported-architectures list as of TGI 3.x |
| `microsoft/Phi-4-mini-instruct-onnx` via ORT | Requires hand-rolling an OpenAI-compat HTTP shim; not a single-container deploy |
| **Ollama 0.5.13+** ✅ | Official OpenAI-compat `/v1/chat/completions`, official Phi-4-mini support, CPU-first, single container, ~150 MB image |

The tradeoff is throughput — vLLM (when CPU images exist) is faster, but for a
workshop demo of "the same OpenAI client points at a self-hosted SLM" the
single-container Ollama path is the most reliable.

## Lessons / gotchas

- The pre-existing APIM backend URL `http://10.224.0.1:8000/v1` in
  `apply-apim-policies.sh` is a **placeholder** so the backend can exist
  before the SLM is deployed. Once you deploy this manifest and re-run the
  policy script, it auto-discovers the real IP via `kubectl get svc`.
- The Service is `type: LoadBalancer` with the internal-LB annotation —
  APIM cannot reach a `ClusterIP` Service from outside the cluster.
- If `kubectl get svc slm-phi4 -n slm` shows `EXTERNAL-IP: <pending>` for
  more than 3 minutes, your AKS load-balancer SKU may not support internal
  LBs (e.g. Basic LB). Workshop infra defaults to Standard LB; if you've
  changed that, drop the internal annotation to use a public LB.
- Phi-4-mini is **multilingual** (supports Indonesian) — the same
  `agent.py` / `workflow.py` calls land natural Indonesian responses on
  this backend too.
