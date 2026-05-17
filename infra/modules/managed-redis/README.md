# `infra/modules/managed-redis/` — Azure Managed Redis with RediSearch

Backing store for APIM's `llm-semantic-cache-lookup` + `llm-semantic-cache-store`
policies. Without this module deployed, those policies are **silent no-ops**
(the built-in APIM cache only handles key-based lookups, not vector similarity).

## Why this is a separate, opt-in module

Per [MS Learn — Enable semantic caching for Azure OpenAI APIs](https://learn.microsoft.com/azure/api-management/azure-openai-enable-semantic-caching),
semantic caching has 5 prerequisites:

1. AOAI APIs imported in APIM ✅ (covered by `apply-apim-policies.sh`)
2. Chat + Embeddings model deployments ✅ (covered by `infra/modules/aoai-singapore/`)
3. APIM managed-identity auth to AOAI ✅ (covered by `apply-apim-policies.sh`)
4. **Azure Managed Redis with the RediSearch module** — this module
5. **Redis configured as APIM's external cache** — this module

This is **opt-in** (off by default) because Managed Redis is the second-longest
provision in the workshop (after APIM itself):

| Tradeoff   | Value |
|------------|-------|
| Provision  | 30-45 min |
| Cost       | ~$0.10/hr (~$2.40/day) at the smallest `Balanced_B0` SKU |
| Region     | Must be a Managed Redis GA region — `indonesiacentral` is NOT supported as of May 2026; module defaults to `southeastasia` (same as AOAI) for low cache↔embedding latency |

## Enable

In your tfvars (e.g. [`infra/env/workshop.tfvars`](../../env/workshop.tfvars)):

```hcl
enable_semantic_cache = true
location_redis        = "southeastasia"  # optional override
redis_sku_name        = "Balanced_B0"    # optional override
```

Then:

```bash
terraform apply \
  -var-file=env/workshop.tfvars \
  -var="apim_publisher_email=you@yourcompany.com" \
  -var="enable_semantic_cache=true"
```

## What gets created

| Resource | Notes |
|----------|-------|
| `azurerm_managed_redis.this` | The new, canonical Managed Redis resource. **Supersedes** the deprecated `azurerm_redis_enterprise_cluster` + `azurerm_redis_enterprise_database` pair. |
| `azurerm_api_management_redis_cache.this` | Wires the Redis cluster into APIM as an external cache so the `llm-semantic-cache-*` policies actually use it. |

## Critical constraints (Terraform plan will reject violations upfront)

When the **RediSearch** module is enabled on the default database:

- `clustering_policy` MUST be `"EnterpriseCluster"` (not `"OSSCluster"`)
- `eviction_policy` MUST be `"NoEviction"` (not `"AllKeysLRU"` etc.)
- The module can ONLY be enabled at cluster creation time — you cannot add
  modules to an existing Managed Redis cluster (per the MS Learn doc and the
  `azurerm_managed_redis` resource docs)

The module hardcodes both required values so you don't have to think about them.

## Verifier behavior

[`scripts/verify-policies.sh`](../../../scripts/verify-policies.sh) Step 4 (semantic cache):

- When this module is **NOT** deployed: probes the APIM `/caches` REST endpoint,
  detects the missing external cache, and yellow-skips with a clear hint
  ("deploy with `-var enable_semantic_cache=true`").
- When this module **IS** deployed: runs two identical large prompts and
  asserts the second response is < half the latency of the first. Should
  flip to green within a minute of the policy being applied.

## Notes on the resource choice

- `azurerm_redis_enterprise_*` resources are deprecated; use `azurerm_managed_redis`
  with a `default_database` block instead.
- The APIM external-cache binding requires `connection_string` (Required), so
  the default database needs `access_keys_authentication_enabled = true` —
  AAD auth on APIM↔Redis only works on the v2 APIM tiers.
- `indonesiacentral` is not yet a Managed Redis region; we use `southeastasia`
  (same as the AOAI embeddings model) for lowest cache lookup latency.
