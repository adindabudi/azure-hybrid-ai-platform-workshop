# ============================================================================
# Microsoft Foundry project (modern, post-classic-hub).
#
# Why this module exists, separately from `modules/aoai-singapore`:
#
# 1. `modules/aoai-singapore` provisions an `azurerm_cognitive_account` of
#    `kind = "OpenAI"`. That resource is what APIM points at for the
#    /openai/deployments/* gateway path. It is intentionally NOT a Foundry
#    project — it is the classic Azure OpenAI account that the OpenAI SDK
#    talks to directly. This is what we want for the high-volume gateway
#    workload (no Foundry overhead on the hot path).
#
# 2. The new Microsoft Foundry experience (post-hub-classic) is a different
#    resource:  `azurerm_cognitive_account` with `kind = "AIServices"` plus
#    `project_management_enabled = true`, with a child
#    `azurerm_cognitive_account_project` resource for the actual project.
#    This is what the docs at
#    https://learn.microsoft.com/azure/foundry/how-to/create-resource-terraform
#    recommend (the legacy `azurerm_ai_foundry` hub resource is deprecated;
#    its own resource page tells you to use `azurerm_cognitive_account`
#    with kind=AIServices instead).
#
# 3. The Foundry project is REQUIRED for two workshop features:
#      * `azure.ai.evaluation.red_team.RedTeam` (cloud red-teaming).
#        Region-locked to East US 2, France Central, Sweden Central,
#        Switzerland West, and US North Central. SEA / IDC will NOT work.
#      * Cloud-side `agent_framework_azure_ai.FoundryEvals` (the
#        observability + evals view in ai.azure.com).
#
# 4. Made opt-in (`enable = false` by default) so the workshop's baseline
#    deploy stays fast and free of cross-region capacity reservations.
#    Operators who need RedTeam / Foundry Evals flip `enable_foundry_project
#    = true` in their tfvars and `terraform apply` adds it.
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
  description = "Region for the Foundry account + project. Must be one of the RedTeam-supported regions: eastus2, francecentral, swedencentral, switzerlandwest, northcentralus."

  validation {
    condition     = contains(["eastus2", "francecentral", "swedencentral", "switzerlandwest", "northcentralus"], var.location)
    error_message = "location must be one of the RedTeam-supported regions (eastus2, francecentral, swedencentral, switzerlandwest, northcentralus); other regions cannot run azure.ai.evaluation.red_team.RedTeam."
  }
}
variable "account_name" {
  type        = string
  description = "Name of the AIServices account (the Foundry resource). Cluster-globally unique."
}
variable "project_name" {
  type        = string
  description = "Name of the Foundry project under the account. RBAC + data-isolation boundary."
}
variable "project_display_name" {
  type        = string
  default     = "Workshop Evals & Red-Team"
  description = "Friendly name shown in the Foundry portal."
}
variable "project_description" {
  type    = string
  default = "Foundry project used by the workshop's eval suite (apps/eval-suite/run_foundry_evals.py) and red-team runner (apps/eval-suite/redteam.py). Created by hybrid-ai-platform-workshop Terraform."
}
variable "deploy_gpt_for_evals" {
  type        = bool
  default     = true
  description = "If true, also create a small gpt-5-mini deployment on the Foundry account so the eval-suite's LLM-as-judge evaluators can hit Foundry directly (instead of routing through APIM/AOAI). Set false to share quota with the SEA AOAI account by configuring the evaluators to point at APIM instead."
}
variable "evals_model_name" {
  type        = string
  default     = "gpt-5-mini"
  description = "Model name for the eval-suite deployment. gpt-5-mini is the workshop default because it consistently has free quota across the subscriptions we tested; bump to gpt-4o-mini / gpt-4.1-mini in a paid fork if your subscription has the entitlement."
}
variable "evals_model_version" {
  type    = string
  default = "2025-08-07"
}
variable "evals_capacity" {
  type        = number
  default     = 10
  description = "Capacity in 1K-TPM for the evals deployment. 10 is enough for the workshop's 5-evaluator x 10-row eval batch."
}
variable "tags" { type = map(string) }

# ----------------------------------------------------------------------------
# Foundry resource (Cognitive Services account, kind=AIServices).
# ----------------------------------------------------------------------------
resource "azurerm_cognitive_account" "foundry" {
  name                  = var.account_name
  resource_group_name   = var.resource_group_name
  location              = var.location
  kind                  = "AIServices"
  sku_name              = "S0"
  custom_subdomain_name = var.account_name
  tags                  = var.tags

  # Required by azurerm_cognitive_account_project: the account MUST have
  # project_management_enabled = true, a managed identity, and a
  # custom_subdomain_name (all three are enforced by the provider).
  project_management_enabled = true

  identity {
    type = "SystemAssigned"
  }
}

# ----------------------------------------------------------------------------
# Foundry project — the actual unit of RBAC / data isolation that
# RedTeam + FoundryEvals + Agent Service consume.
# ----------------------------------------------------------------------------
resource "azurerm_cognitive_account_project" "project" {
  name                 = var.project_name
  cognitive_account_id = azurerm_cognitive_account.foundry.id
  location             = var.location
  display_name         = var.project_display_name
  description          = var.project_description
  tags                 = var.tags

  identity {
    type = "SystemAssigned"
  }
}

# ----------------------------------------------------------------------------
# Optional gpt-5-mini deployment on the Foundry account so the eval suite
# can hit Foundry directly. Disable with `deploy_gpt_for_evals = false`.
#
# Note: cognitive deployments under an AIServices account use the same
# `azurerm_cognitive_deployment` resource as under an OpenAI account
# (the underlying Azure API is identical).
# ----------------------------------------------------------------------------
resource "azurerm_cognitive_deployment" "evals_gpt" {
  count = var.deploy_gpt_for_evals ? 1 : 0

  name                 = var.evals_model_name
  cognitive_account_id = azurerm_cognitive_account.foundry.id

  model {
    format  = "OpenAI"
    name    = var.evals_model_name
    version = var.evals_model_version
  }

  sku {
    name     = "GlobalStandard"
    capacity = var.evals_capacity
  }
}

# ----------------------------------------------------------------------------
# Outputs
# ----------------------------------------------------------------------------
output "account_id" {
  value       = azurerm_cognitive_account.foundry.id
  description = "Full resource ID of the AIServices (Foundry) account."
}

output "account_name" {
  value       = azurerm_cognitive_account.foundry.name
  description = "Name of the AIServices account."
}

output "account_endpoint" {
  value       = azurerm_cognitive_account.foundry.endpoint
  description = "OpenAI-compatible endpoint of the AIServices account (https://<name>.cognitiveservices.azure.com/openai/...)."
}

output "project_id" {
  value       = azurerm_cognitive_account_project.project.id
  description = "Full resource ID of the Foundry project. Required by RedTeam / FoundryEvals."
}

output "project_name" {
  value = azurerm_cognitive_account_project.project.name
}

output "project_endpoints" {
  value       = azurerm_cognitive_account_project.project.endpoints
  description = "Map of endpoint name → URL exposed by the Foundry project (e.g. AI Foundry API endpoint)."
}

output "project_principal_id" {
  value       = try(azurerm_cognitive_account_project.project.identity[0].principal_id, "")
  description = "Principal ID of the project's system-assigned managed identity. Use this to grant the project access to Storage / Cosmos / Search for Agent Service standard setup."
}

output "evals_deployment_name" {
  value       = try(azurerm_cognitive_deployment.evals_gpt[0].name, "")
  description = "Name of the gpt deployment on the Foundry account (empty when deploy_gpt_for_evals=false)."
}

# Region tuple in the shape expected by azure.ai.evaluation.red_team.RedTeam
# and agent_framework_azure_ai.FoundryEvals: subscription_id /
# resource_group_name / project_name. Emit it as a single object so
# downstream scripts can `terraform output -json foundry_azure_ai_project`
# and pass straight into the SDKs.
output "azure_ai_project" {
  value = {
    subscription_id     = split("/", azurerm_cognitive_account_project.project.id)[2]
    resource_group_name = var.resource_group_name
    project_name        = azurerm_cognitive_account_project.project.name
    account_name        = azurerm_cognitive_account.foundry.name
    endpoint            = azurerm_cognitive_account.foundry.endpoint
  }
  description = "Pre-shaped Foundry project descriptor for `azure_ai_project=` kwarg in RedTeam / FoundryEvals."
}
