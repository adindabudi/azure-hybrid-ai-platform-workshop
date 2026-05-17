# ============================================================================
# Azure Managed Redis (with RediSearch module) — backing store for APIM's
# `llm-semantic-cache-lookup` + `llm-semantic-cache-store` policies.
#
# Why this is a separate, opt-in module:
#
# 1. MS Learn states unambiguously that semantic caching requires
#    Azure Managed Redis with the **RediSearch** module enabled, configured
#    as APIM's **external** cache. See
#    https://learn.microsoft.com/azure/api-management/azure-openai-enable-semantic-caching#prerequisites
#    The APIM built-in cache (`internal`) does NOT support vector similarity
#    search, so semantic-cache policies are silent no-ops without this.
#
# 2. Provision time: ~30-45 min for the Managed Redis cluster.
#
# 3. Cost: even the smallest `Balanced_B0` SKU is ~$0.10/hr ($2.40/day),
#    which the typical 1-day Internal/MCAP workshop subscription tolerates
#    but is overkill for a quick `terraform apply` smoke test.
#
# 4. Region availability: Managed Redis is GA in southeastasia (matching
#    our AOAI region for low cache <-> embedding latency) but NOT in
#    indonesiacentral. We use the same `azurerm.sea` provider alias as
#    the AOAI Singapore module so the cache lives in the same region as
#    the embedding model it depends on.
#
# 5. We use the new `azurerm_managed_redis` resource (not the deprecated
#    `azurerm_redis_enterprise_cluster` / `azurerm_redis_enterprise_database`
#    pair — both are explicitly marked deprecated in the azurerm provider
#    in favour of `azurerm_managed_redis`).
#
# 6. `access_keys_authentication_enabled = true` is required because
#    `azurerm_api_management_redis_cache` needs a connection_string (and
#    APIM Developer SKU still uses connection-string auth to external cache;
#    AAD auth on APIM<->Redis is only on the v2 tiers).
# ============================================================================

terraform {
  required_providers {
    azurerm = {
      source                = "hashicorp/azurerm"
      version               = "~> 4.54"
      configuration_aliases = [azurerm]
    }
  }
}

variable "resource_group_name" { type = string }
variable "location" {
  type        = string
  description = "Region for the Managed Redis cluster. Should match the AOAI embeddings region for lowest lookup latency. southeastasia is the workshop default."

  validation {
    # Known Managed Redis GA regions as of May 2026. Update the list as the
    # service expands. Verify with:
    #   az redis-enterprise list-skus --location <region>
    condition = contains([
      "eastus", "eastus2", "westus", "westus2", "westus3",
      "northeurope", "westeurope", "francecentral", "swedencentral",
      "southeastasia", "eastasia", "japaneast", "australiaeast",
      "uksouth", "centralus", "southcentralus",
    ], var.location)
    error_message = "location must be a region where Azure Managed Redis is GA. Verify with `az redis-enterprise list-skus --location <region>`. indonesiacentral is not yet supported."
  }
}
variable "redis_name" {
  type        = string
  description = "Managed Redis cluster name. Globally unique, 3-63 chars, lowercase alphanumeric + dashes."
}
variable "sku_name" {
  type        = string
  default     = "Balanced_B0"
  description = "Managed Redis SKU. `Balanced_B0` is the smallest/cheapest (~$0.10/hr). Bump to `Balanced_B3` if you need geo-replication, or `MemoryOptimized_M10` for larger cache footprints. See the resource page for the full list."
}
variable "api_management_id" {
  type        = string
  description = "Full resource ID of the APIM service to wire this cache into as an external cache."
}
variable "cache_location" {
  type        = string
  default     = "default"
  description = "APIM cache location. `default` means use this cache for any region; otherwise specify the APIM region (e.g. `indonesiacentral`) to scope per-region."
}
variable "tags" { type = map(string) }

# ----------------------------------------------------------------------------
# Managed Redis cluster + default database with the RediSearch module.
#
# The `default_database` block is REQUIRED on create per the provider docs.
# `module { name = "RediSearch" }` is the critical bit — without it,
# `llm-semantic-cache-lookup` will silently return cache misses forever
# (the vector search index can't be created).
# ----------------------------------------------------------------------------
resource "azurerm_managed_redis" "this" {
  name                = var.redis_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = var.sku_name
  tags                = var.tags

  # Required: TLS-encrypted client traffic only.
  # AOF/RDB persistence intentionally disabled — semantic cache entries are
  # cheap to regenerate and we don't want cold-start IO storms on restore.
  default_database {
    access_keys_authentication_enabled = true
    client_protocol                    = "Encrypted"

    # RediSearch imposes two constraints on the default database that
    # `terraform plan` will enforce upfront:
    #   * clustering_policy = "EnterpriseCluster"  (vector search needs the
    #     enterprise-mode shard topology — OSSCluster is rejected).
    #   * eviction_policy   = "NoEviction"         (RediSearch indexes are
    #     not safe under arbitrary eviction; the service rejects the others).
    # Both are good fits for semantic-cache anyway — entries expire on TTL
    # and we want stable enterprise sharding for the vector index.
    clustering_policy = "EnterpriseCluster"
    eviction_policy   = "NoEviction"

    # RediSearch is the module that backs vector similarity search; it MUST
    # be enabled at creation time — you cannot add modules to an existing
    # Managed Redis cluster (per the resource docs).
    module {
      name = "RediSearch"
    }
  }
}

# ----------------------------------------------------------------------------
# Wire the Redis cluster into APIM as an external cache.
#
# This is what makes `llm-semantic-cache-lookup` / -store actually USE the
# Redis backend. Without this binding, the policies silently no-op even if
# the Redis cluster exists.
#
# `connection_string` requires access keys to be enabled on the database
# (see access_keys_authentication_enabled above). The format expected by
# APIM is:  <hostname>:<port>,password=<key>,ssl=True,abortConnect=False
# ----------------------------------------------------------------------------
resource "azurerm_api_management_redis_cache" "this" {
  name              = "semantic-cache"
  api_management_id = var.api_management_id
  redis_cache_id    = azurerm_managed_redis.this.id
  description       = "Azure Managed Redis with RediSearch module — backs the llm-semantic-cache-lookup / llm-semantic-cache-store policies on the openai API."
  cache_location    = var.cache_location

  connection_string = format(
    "%s:%d,password=%s,ssl=True,abortConnect=False",
    azurerm_managed_redis.this.hostname,
    azurerm_managed_redis.this.default_database[0].port,
    azurerm_managed_redis.this.default_database[0].primary_access_key,
  )
}

# ----------------------------------------------------------------------------
# Outputs
# ----------------------------------------------------------------------------
output "redis_id" {
  value       = azurerm_managed_redis.this.id
  description = "Full resource ID of the Managed Redis cluster."
}

output "redis_hostname" {
  value       = azurerm_managed_redis.this.hostname
  description = "DNS hostname of the Managed Redis cluster endpoint."
}

output "redis_port" {
  value       = azurerm_managed_redis.this.default_database[0].port
  description = "TCP port of the Managed Redis database endpoint."
}

output "apim_external_cache_id" {
  value       = azurerm_api_management_redis_cache.this.id
  description = "Full resource ID of the APIM Redis Cache binding. Presence of this output is what enables semantic-cache policies to actually hit Redis."
}
