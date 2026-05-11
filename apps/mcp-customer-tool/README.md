# mcp-customer-tool

Sample [Model Context Protocol](https://modelcontextprotocol.io/) server
used in **M3 — Secure tool access**. Exposes a single
`lookup_customer` tool plus a `list_recent_complaints` helper against a
synthetic 5-row dataset (`customers.json` — no real PII).

The server is intentionally **single-tenant and unauthenticated**. APIM
fronts it with OAuth/PKCE, rate-limit-by-key, and content scanning per
[`policies/mcp-oauth-pkce.xml`](../../policies/mcp-oauth-pkce.xml). This
separation — protocol-naive backend, gateway-owned authorization — is
the central design point of M3.

## Files

| File | Purpose |
| --- | --- |
| `server.py` | FastMCP server with two tools |
| `customers.json` | Synthetic dataset (5 rows) |
| `requirements.txt` | Pinned MCP Python SDK |
| `Dockerfile` | Multi-stage, non-root, `~110 MB` runtime image |
| `deployment.yaml` | k8s Deployment + ClusterIP Service + NetworkPolicy |

## Build and push

```bash
ACR_LOGIN_SERVER=$(az acr show -g rg-aigw-workshop \
  --query "name" -o tsv).azurecr.io

az acr login --name "${ACR_LOGIN_SERVER%%.*}"
docker build -t "${ACR_LOGIN_SERVER}/mcp-customer-tool:1.0" apps/mcp-customer-tool
docker push "${ACR_LOGIN_SERVER}/mcp-customer-tool:1.0"
```

## Deploy into an attendee namespace

`deployment.yaml` references `${ACR_LOGIN_SERVER}` — substitute before
applying:

```bash
export ACR_LOGIN_SERVER=...
envsubst < apps/mcp-customer-tool/deployment.yaml \
  | kubectl apply -n "$NAMESPACE" -f -

kubectl rollout status deployment/mcp-customer-tool -n "$NAMESPACE" --timeout=2m
```

## Local test (no APIM, no k8s)

```bash
cd apps/mcp-customer-tool
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python server.py
# In another shell:
curl -sS http://localhost:8765/sse | head -3
```

## Threat model

See [`docs-site/docs/03-mcp-secure-tool-access/intro.md`](../../docs-site/docs/03-mcp-secure-tool-access/intro.md)
Step 5 — six MCP-specific threats and the APIM mitigation for each.
