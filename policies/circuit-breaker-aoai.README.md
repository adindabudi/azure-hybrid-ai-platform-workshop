# `circuit-breaker-aoai.json` — quick reference

This file is a **backend resource configuration**, not an inline policy XML.

In Azure API Management, the circuit breaker is a property of the **backend
entity** itself (`Microsoft.ApiManagement/service/backends`), not a `<policy>`
element. That is why this file is JSON — it is the body you PUT to ARM, not
something you paste into the policy editor.

## Apply it manually

```bash
SUB=...        # subscription id
RG=...         # resource group
APIM=...       # APIM service name
BACKEND=aoai-sea
ENDPOINT=https://your-aoai.openai.azure.com   # NO trailing slash, NO /openai

# Patch the placeholder URL in-place (do not commit this back)
sed -i.bak "s|REPLACE-AOAI-ENDPOINT.openai.azure.com|${ENDPOINT#https://}|" \
  policies/circuit-breaker-aoai.json

az rest --method put \
  --url "https://management.azure.com/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.ApiManagement/service/${APIM}/backends/${BACKEND}?api-version=2024-05-01" \
  --body @policies/circuit-breaker-aoai.json \
  --headers Content-Type=application/json
```

The workshop automation does this for every AOAI backend automatically
(see `scripts/apply-apim-policies.sh`, Step 3). The file is here as a
reference snippet you can lift into your own IaC.

## Why these values

| Field                                  | Value          | Why                                                                                                                           |
|----------------------------------------|----------------|-------------------------------------------------------------------------------------------------------------------------------|
| `failureCondition.count`               | `5`            | Tolerate brief AOAI hiccups; trip only on a real outage / quota wall.                                                         |
| `failureCondition.interval`            | `PT1M`         | One-minute rolling window — short enough to react fast, long enough to be statistically meaningful.                           |
| `statusCodeRanges`                     | `429`, `500-599` | AOAI signals quota exhaustion with `429 + Retry-After`. 5xx covers genuine backend failure.                                |
| `tripDuration`                         | `PT5M`         | Default cool-off when no `Retry-After` is present.                                                                            |
| `acceptRetryAfter`                     | `true`         | **Required for AOAI.** When AOAI says “come back in 12 hours” we honor it instead of hammering and getting throttled harder. |

## Constraints (per MS Learn, May 2026)

- Not supported on the **Consumption** SKU.
- One rule per backend (Classic + v2 limit).
- Different gateway instances do not synchronize circuit breaker state
  (it is approximate, per-instance).

## Source

- <https://learn.microsoft.com/azure/api-management/backends#circuit-breaker>
- <https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities>
