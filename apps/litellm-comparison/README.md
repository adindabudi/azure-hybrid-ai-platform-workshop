# litellm-comparison

[LiteLLM](https://github.com/BerriAI/litellm) deployed as an
OpenAI-compatible proxy inside the attendee namespace. Used in
**M4 Step 4(c)** to demonstrate that the **same Microsoft Agent
Framework `OpenAIChatClient`** works against APIM, LiteLLM, AOAI, and
Foundry Local without any code changes.

## Files

| File | Purpose |
| --- | --- |
| `config.yaml` | Reference LiteLLM model_list (also embedded into the ConfigMap) |
| `deployment.yaml` | ConfigMap + Secret + Deployment + ClusterIP Service |

## Apply

```bash
# The Secret in deployment.yaml ships with placeholder values. The
# facilitator bootstrap script overwrites them per attendee — for a
# manual run, edit the stringData section first.
kubectl apply -n "$NAMESPACE" -f apps/litellm-comparison/deployment.yaml
kubectl rollout status deployment/litellm -n "$NAMESPACE" --timeout=2m
```

## Smoke-test

```bash
LITELLM_IP=$(kubectl get svc litellm -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
MASTER_KEY=$(kubectl get secret litellm-creds -n "$NAMESPACE" \
  -o jsonpath='{.data.master-key}' | base64 -d)

curl -sS "http://${LITELLM_IP}:4000/v1/chat/completions" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-5-mini-via-litellm","messages":[{"role":"user","content":"hi"}]}'
```

## Why have it at all?

LiteLLM is a popular OAI-compatible proxy that many teams already run.
M4 demonstrates that you can mix it into the same agent codebase as
APIM without changing client code — useful for teams migrating off
LiteLLM onto APIM, or using both side-by-side during a transition.
