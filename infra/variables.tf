variable "prefix" {
  description = "Short prefix used in resource names. Lowercase, 3-6 chars."
  type        = string
  default     = "aigw"

  validation {
    condition     = can(regex("^[a-z]{3,6}$", var.prefix))
    error_message = "prefix must be 3-6 lowercase letters."
  }
}

variable "environment" {
  description = "Environment tag. workshop|dev|test."
  type        = string
  default     = "workshop"
}

variable "resource_group_name" {
  description = "Existing resource group name (created out-of-band by az group create)."
  type        = string
  default     = "rg-aigw-workshop"
}

variable "location" {
  description = "Primary region (Indonesia Central)."
  type        = string
  default     = "indonesiacentral"
}

variable "location_aoai" {
  description = "Region for Azure OpenAI deployments (Southeast Asia / Singapore — AOAI not available in IDC)."
  type        = string
  default     = "southeastasia"
}

variable "attendee_count" {
  description = "Number of workshop attendees. Set to 1 for the worst-case presenter-only run."
  type        = number
  default     = 10

  validation {
    condition     = var.attendee_count >= 1 && var.attendee_count <= 30
    error_message = "attendee_count must be between 1 and 30."
  }
}

variable "apim_publisher_name" {
  description = "Publisher name shown on the APIM developer portal. Visible to anyone with portal access — keep it neutral."
  type        = string
  default     = "Hybrid AI Platform Workshop"
}

variable "apim_publisher_email" {
  description = "Publisher email; receives notifications from APIM. The placeholder in workshop.tfvars works for unattended deploys; override with your real ops contact for production."
  type        = string

  validation {
    # APIM rejects deliveries to RFC 2606 reserved TLDs (e.g. *.invalid)
    # *after* a slow create — `terraform apply` succeeds but every
    # notification then errors in the portal. Catch the placeholder here.
    condition     = !endswith(lower(var.apim_publisher_email), "example.invalid")
    error_message = "apim_publisher_email is still the placeholder 'example.invalid' value. Override it in your tfvars (or via -var) before applying — use any real address you can receive at, e.g. ops-handle@yourcompany.com."
  }

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.apim_publisher_email))
    error_message = "apim_publisher_email must look like a valid email (user@host.tld)."
  }
}

variable "aks_node_count" {
  description = "AKS system node count. 2 is enough for the workshop."
  type        = number
  default     = 2
}

variable "aks_node_vm_size" {
  description = "AKS VM size. D4s_v5 = 4 vCPU / 16 GiB."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "enable_cilium" {
  description = "Switch AKS network data plane to Cilium. Set false on the first apply (enables Overlay only), then true on the second apply. New-cluster greenfield deploys can start at true."
  type        = bool
  default     = false
}

variable "aoai_gpt_4o_mini_capacity" {
  description = "AOAI primary chat deployment capacity in 1K-TPM units. Defaults assume the workshop's `gpt-5-mini` GlobalStandard deployment; bump for higher throughput, or swap to gpt-4o-mini / gpt-4.1-mini in your fork."
  type        = number
  default     = 50 # = 50K TPM
}

variable "aoai_embedding_capacity" {
  description = "AOAI text-embedding-3-large deployment capacity in 1K-TPM units (text-embedding-3-small not in SEA)."
  type        = number
  default     = 50
}

# ---------- Foundry project (opt-in) ----------

variable "enable_foundry_project" {
  description = "If true, also provision a Microsoft Foundry resource (AIServices account + project) so apps/eval-suite/redteam.py + run_foundry_evals.py can use the cloud RedTeam / FoundryEvals services. Off by default to keep the baseline workshop deploy fast and free of cross-region quota holds."
  type        = bool
  default     = false
}

variable "location_foundry" {
  description = "Region for the Foundry account + project. Must be one of the RedTeam-supported regions: eastus2, francecentral, swedencentral, switzerlandwest, northcentralus."
  type        = string
  default     = "eastus2"

  validation {
    condition     = contains(["eastus2", "francecentral", "swedencentral", "switzerlandwest", "northcentralus"], var.location_foundry)
    error_message = "location_foundry must be one of the RedTeam-supported regions (eastus2, francecentral, swedencentral, switzerlandwest, northcentralus); other regions cannot run azure.ai.evaluation.red_team.RedTeam."
  }
}

variable "foundry_deploy_gpt_for_evals" {
  description = "If true (default), create a small gpt-5-mini deployment on the Foundry account so the eval-suite can talk to Foundry directly. Set false to route evals through the SEA AOAI account / APIM instead."
  type        = bool
  default     = true
}

variable "foundry_evals_capacity" {
  description = "Capacity in 1K-TPM for the Foundry-side gpt-5-mini deployment used by the eval suite. 10 is plenty for the 5 × 10-row batch in apps/eval-suite/."
  type        = number
  default     = 10
}

# ---------- Managed Redis for APIM semantic cache (opt-in) ----------
#
# `llm-semantic-cache-lookup` + `llm-semantic-cache-store` REQUIRE Azure
# Managed Redis with the RediSearch module configured as APIM's external
# cache. The built-in APIM cache only handles key-based lookups, not vector
# similarity. See
# https://learn.microsoft.com/azure/api-management/azure-openai-enable-semantic-caching#prerequisites
#
# This is opt-in (off by default) because:
#   - Managed Redis takes ~30-45 min to provision (long pole second only to APIM).
#   - Even the smallest Balanced_B0 SKU is ~$0.10/hr (~$2.40/day).
#   - The smoke test passes without it (Step 4 will yellow-skip when the
#     external cache binding is absent — see scripts/verify-policies.sh).

variable "enable_semantic_cache" {
  description = "If true, provision an Azure Managed Redis cluster with the RediSearch module and wire it as APIM's external cache so llm-semantic-cache-* policies actually hit Redis. Off by default to keep the baseline workshop deploy fast and cheap."
  type        = bool
  default     = false
}

variable "location_redis" {
  description = "Region for the Managed Redis cluster. Should match (or be close to) the AOAI embeddings region for lowest cache-lookup latency. southeastasia (same as location_aoai) is the workshop default. indonesiacentral is NOT supported by Managed Redis as of May 2026."
  type        = string
  default     = "southeastasia"
}

variable "redis_sku_name" {
  description = "Managed Redis SKU. Balanced_B0 is the smallest/cheapest. Bump to Balanced_B3 for geo-replication, MemoryOptimized_M10 for a bigger cache."
  type        = string
  default     = "Balanced_B0"
}

variable "common_tags" {
  description = "Tags applied to every resource. Override or extend per workshop run."
  type        = map(string)
  default = {
    purpose     = "hybrid-ai-platform-workshop"
    cost-center = "hybrid-ai-workshop"
    deployed-by = "terraform"
    repo        = "hybrid-ai-platform-workshop"
  }
}
