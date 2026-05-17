data "azurerm_client_config" "current" {}

# Workshop RG is created out-of-band. We treat it as a data source so
# `terraform destroy` never accidentally cascades into the RG itself.
data "azurerm_resource_group" "workshop" {
  name = var.resource_group_name
}

# ---------- Networking ----------

module "networking" {
  source = "./modules/networking"

  resource_group_name = data.azurerm_resource_group.workshop.name
  location            = var.location
  vnet_name           = local.name.vnet
  tags                = local.tags
}

# ---------- Observability ----------

module "observability" {
  source = "./modules/observability"

  resource_group_name       = data.azurerm_resource_group.workshop.name
  location                  = var.location
  log_analytics_name        = local.name.law
  application_insights_name = local.name.appi
  tags                      = local.tags
}

# ---------- Data plane ----------

module "data" {
  source = "./modules/data"

  resource_group_name = data.azurerm_resource_group.workshop.name
  location            = var.location
  prefix              = var.prefix
  suffix              = local.suffix

  key_vault_name = local.name.kv
  storage_name   = local.name.st
  acr_name       = local.name.acr
  search_name    = local.name.srch
  cosmos_name    = local.name.cosmos

  tenant_id         = data.azurerm_client_config.current.tenant_id
  current_object_id = data.azurerm_client_config.current.object_id
  attendees         = local.attendees

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id

  tags = local.tags
}

# ---------- Azure OpenAI in Singapore (cross-region) ----------

module "aoai_singapore" {
  source = "./modules/aoai-singapore"

  providers = {
    azurerm = azurerm.sea
  }

  resource_group_name  = data.azurerm_resource_group.workshop.name
  location             = var.location_aoai
  aoai_name            = local.name.aoai
  content_safety_name  = local.name.cog_safety
  gpt_4o_mini_capacity = var.aoai_gpt_4o_mini_capacity
  embedding_capacity   = var.aoai_embedding_capacity

  tags = local.tags
}

# ---------- Microsoft Foundry project (opt-in) ----------
# Provides the project descriptor required by:
#   - apps/eval-suite/redteam.py            (azure.ai.evaluation.red_team.RedTeam)
#   - apps/eval-suite/run_foundry_evals.py  (cloud-side FoundryEvals view)
# Region-locked to one of: eastus2, francecentral, swedencentral,
# switzerlandwest, northcentralus (per RedTeam service availability).
# Disabled by default (enable_foundry_project = false in workshop.tfvars).
module "foundry_project" {
  source = "./modules/foundry-project"
  count  = var.enable_foundry_project ? 1 : 0

  providers = {
    azurerm = azurerm.foundry
  }

  resource_group_name  = data.azurerm_resource_group.workshop.name
  location             = var.location_foundry
  account_name         = local.name.foundry
  project_name         = local.name.foundry_pr
  deploy_gpt_for_evals = var.foundry_deploy_gpt_for_evals
  evals_capacity       = var.foundry_evals_capacity

  tags = local.tags
}

# ---------- APIM Developer (long pole — ~25 min provision) ----------

module "apim" {
  source = "./modules/apim-developer"

  resource_group_name = data.azurerm_resource_group.workshop.name
  location            = var.location
  apim_name           = local.name.apim
  publisher_name      = var.apim_publisher_name
  publisher_email     = var.apim_publisher_email

  log_analytics_workspace_id               = module.observability.log_analytics_workspace_id
  application_insights_id                  = module.observability.application_insights_id
  application_insights_instrumentation_key = module.observability.application_insights_instrumentation_key

  attendees = local.attendees

  tags = local.tags
}

# ---------- Azure Managed Redis for APIM semantic cache (opt-in) ----------
# Backs the `llm-semantic-cache-lookup` + `llm-semantic-cache-store` policies.
# Without this module deployed, those policies silently no-op (the APIM
# built-in cache only does key lookups, not vector similarity).
# Disabled by default — see variables.tf for the cost / latency tradeoff.
module "managed_redis" {
  source = "./modules/managed-redis"
  count  = var.enable_semantic_cache ? 1 : 0

  providers = {
    azurerm = azurerm.sea
  }

  resource_group_name = data.azurerm_resource_group.workshop.name
  location            = var.location_redis
  redis_name          = local.name.redis
  sku_name            = var.redis_sku_name
  api_management_id   = module.apim.apim_id
  cache_location      = var.location # bind cache to the APIM region (indonesiacentral)

  tags = local.tags
}

# ---------- AKS ----------

module "aks" {
  source = "./modules/aks"

  resource_group_name = data.azurerm_resource_group.workshop.name
  location            = var.location
  aks_name            = local.name.aks
  node_count          = var.aks_node_count
  node_vm_size        = var.aks_node_vm_size
  attendees           = local.attendees
  enable_cilium       = var.enable_cilium

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
  acr_id                     = module.data.acr_id
  key_vault_id               = module.data.key_vault_id

  tags = local.tags
}
