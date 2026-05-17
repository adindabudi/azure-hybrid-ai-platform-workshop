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
  description = "Content Safety account name. Created with the F0 (free) SKU by default — F0 is available on most subscriptions including Internal/MCAP/trial. Set `deploy_content_safety = false` to skip (e.g. on the rare subscription where even F0 is blocked)."
  default     = ""
}
variable "deploy_content_safety" {
  type        = bool
  default     = true
  description = "If true (default), create an Azure AI Content Safety account with the F0 free SKU and wire it into the APIM `llm-content-safety` policy. Set false to skip on subscriptions that block ContentSafety entirely."
}
variable "content_safety_sku" {
  type        = string
  default     = "F0"
  description = "Content Safety SKU. `F0` (free) works on most subscriptions; `S0` requires a quota/feature entitlement that Internal/MCAP subscriptions typically lack."
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
# subscriptions we tested in May 2026. In a paid production subscription,
# change the deployment name + model + version below to whichever model
# your contract entitles you to.
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
# Content Safety — F0 (free) by default
#
# F0 is generally available on Internal / MCAP / trial subscriptions where S0
# is blocked by quota entitlement. To upgrade in a production fork, set
# `content_safety_sku = "S0"`. To skip entirely (subscription has no CS
# entitlement at all), set `deploy_content_safety = false`.
#
# When enabled, this account is wired into the APIM `llm-content-safety`
# policy by `scripts/apply-apim-policies.sh --with-content-safety` (which
# now also picks up the account name automatically from the
# `content_safety_name` Terraform output).
# ============================================================================
resource "azurerm_cognitive_account" "content_safety" {
  count = var.deploy_content_safety ? 1 : 0

  name                  = var.content_safety_name
  resource_group_name   = var.resource_group_name
  location              = var.location
  kind                  = "ContentSafety"
  sku_name              = var.content_safety_sku
  custom_subdomain_name = var.content_safety_name
  tags                  = var.tags

  identity {
    type = "SystemAssigned"
  }
}

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
  description = "Content Safety endpoint URL. Empty when CS account is disabled via deploy_content_safety=false."
  value       = try(azurerm_cognitive_account.content_safety[0].endpoint, "")
}

output "content_safety_id" {
  description = "Content Safety resource ID. Empty when disabled."
  value       = try(azurerm_cognitive_account.content_safety[0].id, "")
}

output "content_safety_name" {
  description = "Content Safety account name (mirrors the variable). Empty when disabled."
  value       = try(azurerm_cognitive_account.content_safety[0].name, "")
}
