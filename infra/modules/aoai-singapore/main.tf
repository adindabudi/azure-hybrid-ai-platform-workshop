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
variable "location" { type = string }
variable "aoai_name" { type = string }
variable "content_safety_name" {
  type        = string
  description = "Content Safety account name. The account is intentionally not created in the default workshop deploy because many test subscriptions lack the required entitlement; kept for API compatibility so the variable can be set by forks that have the entitlement."
  default     = ""
}
variable "gpt_4o_mini_capacity" { type = number }
variable "embedding_capacity" { type = number }
variable "tags" { type = map(string) }

# ============================================================================
# Azure OpenAI account — deployed to the AOAI region (e.g. SEA / Singapore)
# because AOAI is not yet available in the workshop's primary region (e.g.
# Indonesia Central). Verify with:
#   az cognitivesservices account list-skus \
#       --location <your-primary-region> --kind OpenAI
# ============================================================================

resource "azurerm_cognitive_account" "aoai" {
  name                  = var.aoai_name
  resource_group_name   = var.resource_group_name
  location              = var.location
  kind                  = "OpenAI"
  sku_name              = "S0"
  custom_subdomain_name = var.aoai_name
  tags                  = var.tags

  identity {
    type = "SystemAssigned"
  }
}

# Primary chat deployment behind APIM.
#
# The workshop defaults to `gpt-5-mini` (GlobalStandard) because many test
# subscriptions have zero free quota for `gpt-4o-mini` / `gpt-4.1-mini` in
# the SEA region, while `gpt-5-mini` reliably has free quota across all the
# Internal subscriptions we tested in May 2026. In a customer's paid
# production subscription, change the deployment name + model + version
# below to whichever model your contract entitles you to.
resource "azurerm_cognitive_deployment" "gpt_4o_mini" {
  name                 = "gpt-5-mini"
  cognitive_account_id = azurerm_cognitive_account.aoai.id

  model {
    format  = "OpenAI"
    name    = "gpt-5-mini"
    version = "2025-08-07"
  }

  sku {
    name     = "GlobalStandard"
    capacity = var.gpt_4o_mini_capacity
  }
}

# text-embedding-3-large — used by APIM `llm-semantic-cache-lookup`
# AND by the workshop RAG demo. We use -3-large rather than -3-small
# because -3-small is not available in every SEA region as of May 2026;
# verify with `az cognitiveservices model list` in your target region.
resource "azurerm_cognitive_deployment" "embedding" {
  name                 = "text-embedding-3-large"
  cognitive_account_id = azurerm_cognitive_account.aoai.id

  model {
    format  = "OpenAI"
    name    = "text-embedding-3-large"
    version = "1"
  }

  sku {
    name     = "Standard"
    capacity = var.embedding_capacity
  }
}

# ============================================================================
# Content Safety — SKIPPED by default for this workshop
#
# Microsoft Content Safety requires a SKU entitlement (QuotaId/Feature) that
# Internal / MCAP / many trial subscriptions do not have. The default
# behaviour is therefore to skip the CS account here, and demonstrate one of
# the two production paths in the docs:
#
#   1. Use AOAI's built-in content filters for the dev demo, OR
#   2. Run the Content Safety **container** on AKS for in-region scanning
#      (see `apps/content-safety-cpu/`)
#
# In a paid customer subscription with full entitlement, uncomment the
# `azurerm_cognitive_account` block for content safety in your fork and
# wire its endpoint into the `llm-content-safety` APIM policy via
# managed identity.
# ============================================================================

output "endpoint" {
  value = azurerm_cognitive_account.aoai.endpoint
}

output "aoai_id" {
  value = azurerm_cognitive_account.aoai.id
}

output "aoai_name" {
  value = azurerm_cognitive_account.aoai.name
}

output "gpt_4o_mini_deployment_name" {
  value = azurerm_cognitive_deployment.gpt_4o_mini.name
}

output "embedding_deployment_name" {
  value = azurerm_cognitive_deployment.embedding.name
}

output "content_safety_endpoint" {
  description = "Content Safety endpoint URL. Empty when CS account is skipped due to subscription entitlement."
  value       = ""
}

output "content_safety_id" {
  description = "Content Safety resource ID. Empty when skipped."
  value       = ""
}
