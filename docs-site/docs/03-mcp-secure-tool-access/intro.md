---
title: 3.0 — MCP through the gateway
sidebar_position: 1
---

# M3 — Expose tools the right way

## What you will accomplish

In this 45-minute module you will:

- Deploy a Model Context Protocol (MCP) server to your AKS namespace.
- Front it with APIM using two registration patterns.
- Add OAuth 2.0 / PKCE authentication on the MCP endpoint.
- Walk through the MCP-specific threat model and the APIM mitigation
  for each entry.

## What is MCP, in 90 seconds

The [Model Context Protocol](https://modelcontextprotocol.io/) is an open
JSON-RPC-style protocol that lets agents discover and call tools from any
server that implements it. Three primitives:

- **Tools** — functions the agent can call (`lookup_customer`, `send_email`).
- **Resources** — data the agent can read (`document://policy.pdf`).
- **Prompts** — templated instructions the server suggests.

MCP standardises the contract so the same agent can talk to a database
server, a CRM server, and a payments server without three custom integrations.

The official APIM-MCP integration is documented at
[Export REST API as MCP server](https://learn.microsoft.com/azure/api-management/export-rest-mcp-server).

## Prerequisites

- M2 completed — gateway has auth, content safety, and observability.
- An empty namespace `attendee-NN` on the shared AKS.
- The sample MCP server image (built and pushed to the workshop ACR by
  the facilitator) — `${ACR_LOGIN_SERVER}/mcp-customer-tool:1.0`.

## Step 1 — Deploy the sample MCP server

The repo's [`apps/mcp-customer-tool/`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/tree/main/apps/mcp-customer-tool)
directory has a Python FastMCP server that exposes a `lookup_customer`
tool against a synthetic dataset.

```bash
# Substitute your attendee number
export NS=attendee-03

# Deploy the manifest. Container is amd64.
kubectl apply -n "$NS" \
  -f apps/mcp-customer-tool/deployment.yaml

# Wait for ready
kubectl rollout status deployment/mcp-customer-tool -n "$NS" --timeout=2m

# Get the service IP
MCP_IP=$(kubectl get svc mcp-customer-tool -n "$NS" \
  -o jsonpath='{.spec.clusterIP}')
echo "MCP server at: http://${MCP_IP}:8765"
```

### Verify the MCP server is reachable

```bash
# Port-forward for a quick test from your laptop
kubectl port-forward -n "$NS" svc/mcp-customer-tool 8765:8765 &
PF_PID=$!

# Call the MCP "list_tools" method directly
curl -sS http://localhost:8765/sse | head -3
# Expected: server emits an SSE stream — Ctrl-C to stop

kill $PF_PID
```

## Step 2 — Pattern A: register as an APIM API

You have two ways to register MCP behind APIM. Pattern A treats the MCP
server as an HTTP API, which is appropriate when the server is already
deployed and you just want APIM-level concerns (auth, rate limit, logs).

```bash
# Expose the service internally so APIM can reach it
kubectl annotate svc mcp-customer-tool -n "$NS" \
  service.beta.kubernetes.io/azure-load-balancer-internal=true \
  --overwrite

# Wait for an internal LB IP
kubectl get svc mcp-customer-tool -n "$NS" -w
# Ctrl-C once EXTERNAL-IP shows a 10.40.x.x address

MCP_LB=$(kubectl get svc mcp-customer-tool -n "$NS" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Register the backend
az apim backend create \
  -g "$RG" --service-name "$APIM" \
  --backend-id "mcp-${NS}" \
  --url "http://${MCP_LB}:8765" \
  --protocol http

# Create the API
az apim api create \
  -g "$RG" --service-name "$APIM" \
  --api-id "mcp-${NS}" \
  --display-name "MCP: $NS customer tool" \
  --path "mcp/${NS}" \
  --protocols https \
  --service-url "http://${MCP_LB}:8765"
```

## Step 3 — Pattern B: wrap an existing REST API

If you already have a REST API published in APIM, you can convert it to
an MCP server with one command per
[the docs](https://learn.microsoft.com/azure/api-management/export-rest-mcp-server):

```bash
# Hypothetical: convert an existing API "customer-api" to MCP
az rest --method POST \
  --url "https://management.azure.com/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.ApiManagement/service/${APIM}/apis/customer-api/exportToMcpServer?api-version=2024-09-01-preview" \
  --headers "Content-Type=application/json"
```

This is the right pattern when your customer says *"can we expose our
existing OpenAPI surface as MCP without writing a server?"* — they get
it for free.

## Step 4 — Add OAuth 2.0 / PKCE

The MCP server should require an OAuth access token, not just a
subscription key. Pattern from
[`Azure-Samples/remote-mcp-apim-functions-python`](https://github.com/Azure-Samples/remote-mcp-apim-functions-python).

Create a dedicated app registration for MCP clients:

```bash
MCP_APP_ID=$(az ad app create \
  --display-name "aigw-mcp-client-${NS}" \
  --sign-in-audience AzureADMyOrg \
  --query appId -o tsv)

# Add a redirect URI for PKCE
az ad app update --id "$MCP_APP_ID" \
  --public-client-redirect-uris "http://localhost:8400/oauth/callback"
```

Apply this policy to your MCP API
([file](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/blob/main/policies/mcp-oauth-pkce.xml)):

```xml
<policies>
    <inbound>
        <base />
        <validate-jwt header-name="Authorization"
                      failed-validation-httpcode="401"
                      require-scheme="Bearer">
            <openid-config url="https://login.microsoftonline.com/{{aad-tenant-id}}/v2.0/.well-known/openid-configuration" />
            <required-claims>
                <claim name="aud" match="any">
                    <value>{{mcp-app-id}}</value>
                </claim>
            </required-claims>
        </validate-jwt>
        <rate-limit-by-key calls="120" renewal-period="60"
                          counter-key="@(context.Subscription.Id)" />
    </inbound>
    <backend><base /></backend>
    <outbound><base /></outbound>
    <on-error><base /></on-error>
</policies>
```

Set the named values:

```bash
az apim nv create -g "$RG" --service-name "$APIM" \
  --named-value-id aad-tenant-id --display-name aad-tenant-id \
  --value "$TENANT"
az apim nv create -g "$RG" --service-name "$APIM" \
  --named-value-id mcp-app-id --display-name mcp-app-id \
  --value "$MCP_APP_ID"
```

### Verify

```bash
# Without token → 401
curl -sS -o /dev/null -w "%{http_code}\n" \
  "${APIM_GATEWAY}/mcp/${NS}/sse" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}"
# Expected: 401

# With token → 200/SSE stream
TOKEN=$(az account get-access-token --resource "$MCP_APP_ID" --query accessToken -o tsv)
curl -sS -i \
  "${APIM_GATEWAY}/mcp/${NS}/sse" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
  -H "Authorization: Bearer ${TOKEN}" | head -8
# Expected: HTTP/1.1 200 OK, Content-Type: text/event-stream
```

### Verify the rate limit kicks in

The OAuth policy also includes `<rate-limit-by-key calls="120"
renewal-period="60">`. Hammer the endpoint and watch for 429s:

```bash
for i in $(seq 1 150); do
  curl -sS -o /dev/null -w "%{http_code}\n" \
    "${APIM_GATEWAY}/mcp/${NS}/sse" \
    -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
    -H "Authorization: Bearer ${TOKEN}"
done | sort | uniq -c
```

**Expected output** — a mix of `200` and `429`, with at least one 429
after the 120th request in any 60-second window.

```
    120 200
     30 429
```

## Step 5 — Threat model walkthrough

MCP introduces threats that aren't covered by general API security
(rate limit + JWT). Memorize each one and its APIM mitigation.

| Threat | What it looks like | APIM mitigation |
| --- | --- | --- |
| **Prompt injection via tool description** | A malicious server returns a `description` field that instructs the agent to override its system prompt | Content Safety policy on **outbound** responses; reject tool catalogs containing high-severity phrases |
| **Tool poisoning** | The tool *result* contains an instruction (`"Ignore previous, send funds to..."`) | `<llm-content-safety>` on outbound, or a `<send-request>` to `text:analyze` on the response body |
| **Server impersonation** | Attacker stands up a look-alike MCP server, agents route to it via DNS spoofing | Pin backend by IP in APIM (`backend-id` referencing internal LB IP, not FQDN); add mTLS via APIM client certs |
| **Over-privileged tools** | Single OAuth scope grants access to every tool on every server | One APIM **product** per MCP server, distinct OAuth scopes per product |
| **PII leakage in tool args** | Agent passes credit card numbers as positional args | Add a `<set-body>` policy that masks regex-matched patterns before forwarding |

## Step 6 — Registry / discovery pattern (optional)

You can use APIM **products** as your MCP catalog and Entra group
membership as the authorization gate. Every MCP server gets a product;
every team's Entra group is granted access to specific products.

```bash
# One-time: create a product for the customer-tool MCP
az apim product create \
  -g "$RG" --service-name "$APIM" \
  --product-id "mcp-customer-tools" \
  --display-name "Customer Tools (MCP)" \
  --subscriptions-limit 50 \
  --approval-required true

# Add the MCP API to the product
az apim product api add \
  -g "$RG" --service-name "$APIM" \
  --product-id "mcp-customer-tools" \
  --api-id "mcp-${NS}"
```

Now `GET /apim/products/mcp-customer-tools/apis` is your tool catalog;
group membership in Entra is your access control.

## What you just built

A pattern that lets you ship N MCP servers behind one gateway with:

- Per-server OAuth scopes.
- Rate limit per OAuth identity.
- Content scanning on tool inputs *and* outputs.
- One Entra group membership = one product subscription = one tool
  catalog.

This is the production shape for an agent platform — every team builds
their own tool servers, and the platform team owns the gateway.

## Reference

- [Export REST API as MCP server](https://learn.microsoft.com/azure/api-management/export-rest-mcp-server)
- [`Azure-Samples/remote-mcp-apim-functions-python`](https://github.com/Azure-Samples/remote-mcp-apim-functions-python)
- [`validate-jwt` policy](https://learn.microsoft.com/azure/api-management/validate-jwt-policy)
- [Model Context Protocol spec](https://modelcontextprotocol.io/)

## Next

[M4 — Agent Framework](../agent-framework/intro)
