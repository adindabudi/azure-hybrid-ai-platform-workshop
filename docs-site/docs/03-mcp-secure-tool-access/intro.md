---
title: 3.0 — MCP through the gateway
sidebar_position: 1
---

# M3 — Expose tools the right way

## What you will accomplish

In this 45-minute module you will:

- Deploy a Model Context Protocol (MCP) server to your AKS namespace.
- Hit it through the APIM gateway your facilitator pre-registered for
  you, with OAuth 2.0 / PKCE.
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

- M2 done — gateway has auth, content safety, and observability.
- `kubectl` is pointed at the workshop AKS and your context is set to
  your attendee namespace.
- Your facilitator has built and pushed the sample MCP server image to
  the workshop ACR — `${ACR_LOGIN_SERVER}/mcp-customer-tool:1.0`.

## Step 1 — Deploy the sample MCP server (your namespace)

The repo's [`apps/mcp-customer-tool/`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/tree/main/apps/mcp-customer-tool)
directory has a Python FastMCP server that exposes a `lookup_customer`
tool against a synthetic dataset.

```bash
# Substitute your attendee number if not already set
export NAMESPACE="${NAMESPACE:-attendee-03}"

kubectl apply -n "$NAMESPACE" \
  -f apps/mcp-customer-tool/deployment.yaml

kubectl rollout status deployment/mcp-customer-tool -n "$NAMESPACE" --timeout=2m
```

### Verify the MCP server is reachable inside your namespace

```bash
# Port-forward for a quick test from your laptop
kubectl port-forward -n "$NAMESPACE" svc/mcp-customer-tool 8765:8765 &
PF_PID=$!

# Call the MCP "list_tools" method directly
curl -sS http://localhost:8765/sse | head -3
# Expected: server emits an SSE stream — Ctrl-C to stop

kill $PF_PID
```

## Step 2 — Hit your MCP server through APIM

Your facilitator already registered an APIM API for each attendee's MCP
server at `${APIM_GATEWAY_URL}/mcp/${NAMESPACE}/`. Backend pinning,
OAuth/PKCE policy, and rate-limit-by-key are applied per
[`policies/mcp-oauth-pkce.xml`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/blob/main/policies/mcp-oauth-pkce.xml).

### Verify

```bash
# Without token → 401
curl -sS -o /dev/null -w "%{http_code}\n" \
  "${APIM_GATEWAY_URL}/mcp/${NAMESPACE}/sse" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}"
# Expected: 401
```

Your facilitator will share the MCP app ID at the workshop:

```bash
MCP_APP_ID="<from facilitator>"
TOKEN=$(az account get-access-token --resource "$MCP_APP_ID" --query accessToken -o tsv)

curl -sS -i \
  "${APIM_GATEWAY_URL}/mcp/${NAMESPACE}/sse" \
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
    "${APIM_GATEWAY_URL}/mcp/${NAMESPACE}/sse" \
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

## Step 3 — Read the OAuth/PKCE policy

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

The interesting design choice here is that **MCP doesn't define an auth
story** — the protocol carries no token. APIM bolts the OAuth check on
at the gateway layer, before the MCP server sees the request. The MCP
server stays single-tenant and unauthenticated; APIM does the multi-tenant
authorization.

## Step 4 — Pattern B: wrap an existing REST API as MCP

If you already have a REST API published in APIM, you can convert it to
an MCP server with one command per
[the docs](https://learn.microsoft.com/azure/api-management/export-rest-mcp-server).
This is admin work — your facilitator can demo it live during the
workshop, or you can read the
[Facilitator Guide](../90-facilitator-guide/apply-policies.md) for the exact
CLI.

The point: when someone asks *"can we expose our existing OpenAPI
surface as MCP without writing a server?"* — the answer is yes, for free.

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

## Step 6 — Registry / discovery pattern

You can use APIM **products** as your MCP catalog and Entra group
membership as the authorization gate. Every MCP server gets a product;
every team's Entra group is granted access to specific products.

The catalog endpoint becomes:

```
GET /apim/products/mcp-customer-tools/apis
```

Entra group membership is your access control. Admin steps to wire this
up are in the
[Facilitator Guide](../90-facilitator-guide/apply-policies.md).

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
- Admin steps to register MCP APIs: [Facilitator Guide → Apply policies](../90-facilitator-guide/apply-policies.md)

## Next

[M4 — Agent Framework](../agent-framework/intro)
