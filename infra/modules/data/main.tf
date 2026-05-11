terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.54"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.7"
    }
  }
}

variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "prefix" { type = string }
variable "suffix" { type = string }
variable "key_vault_name" { type = string }
variable "storage_name" { type = string }
variable "acr_name" { type = string }
variable "search_name" { type = string }
variable "cosmos_name" { type = string }
variable "tenant_id" { type = string }
variable "current_object_id" { type = string }
variable "attendees" { type = list(string) }
variable "log_analytics_workspace_id" { type = string }
variable "tags" { type = map(string) }

# ============================================================================
# Key Vault (RBAC mode — modern; no access policies)
# ============================================================================

resource "azurerm_key_vault" "this" {
  name                       = var.key_vault_name
  resource_group_name        = var.resource_group_name
  location                   = var.location
  tenant_id                  = var.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  tags                       = var.tags
}

# Grant the deploying principal `Key Vault Administrator` so secret writes succeed.
resource "azurerm_role_assignment" "kv_admin_self" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = var.current_object_id
}

# ============================================================================
# Storage account (workshop assets, eval datasets)
# ============================================================================

resource "azurerm_storage_account" "this" {
  name                            = var.storage_name
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  # Tenant policy disables shared-key auth on storage. All access via Entra ID.
  shared_access_key_enabled = false
  tags                      = var.tags
}

# The deploying principal needs Blob Data Owner so the post-create container
# provisioning (below) can authenticate via AAD instead of shared key.
resource "azurerm_role_assignment" "storage_blob_owner_self" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = var.current_object_id
}

# One blob container per attendee — isolation lever for M4 / M5 datasets.
resource "azurerm_storage_container" "attendee" {
  for_each              = toset(var.attendees)
  name                  = each.value
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"

  depends_on = [azurerm_role_assignment.storage_blob_owner_self]
}

resource "azurerm_storage_container" "shared" {
  name                  = "shared-assets"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"

  depends_on = [azurerm_role_assignment.storage_blob_owner_self]
}

# ============================================================================
# ACR — Basic SKU is enough for a 1-day workshop
# ============================================================================

resource "azurerm_container_registry" "this" {
  name                = var.acr_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = var.tags
}

# ============================================================================
# Azure AI Search — Basic in IDC.
# Note: IDC has NO semantic ranker / agentic retrieval / AI enrichment.
# Workshop M4.5 demonstrates this gap explicitly and uses Cosmos DB
# vector + semantic reranker (Preview) as the in-Indonesia workaround.
# ============================================================================

resource "azurerm_search_service" "this" {
  name                         = var.search_name
  resource_group_name          = var.resource_group_name
  location                     = var.location
  sku                          = "basic"
  replica_count                = 1
  partition_count              = 1
  local_authentication_enabled = true # workshop convenience; prod = MI only
  tags                         = var.tags

  identity {
    type = "SystemAssigned"
  }
}

# ============================================================================
# Cosmos DB for NoSQL — Free Tier (1000 RU/s, 25 GB)
# Vector search enabled so M4.5 can demonstrate the in-IDC reranker workaround.
# ============================================================================

resource "azurerm_cosmosdb_account" "this" {
  name                = var.cosmos_name
  resource_group_name = var.resource_group_name
  location            = var.location
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"
  # `free_tier_enabled = true` is rejected on Internal/MCAP and several trial
  # subscription types. We default to false to keep this repo deployable on
  # any sub; flip to true in your fork if your subscription supports it.
  free_tier_enabled = false
  tags              = var.tags

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.location
    failover_priority = 0
  }

  # Free tier is provisioned-throughput (1000 RU/s, 25 GB), NOT serverless.
  # Keep only the vector-search capability for M4.5 (in-IDC reranker workaround).
  capabilities {
    name = "EnableNoSQLVectorSearch"
  }
}

resource "azurerm_cosmosdb_sql_database" "workshop" {
  name                = "workshop"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.this.name
  throughput          = 400 # min for provisioned shared throughput
}

# One container per attendee for agent state / threads / eval store.
resource "azurerm_cosmosdb_sql_container" "attendee_state" {
  for_each = toset(var.attendees)

  name                = "state-${each.value}"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.this.name
  database_name       = azurerm_cosmosdb_sql_database.workshop.name
  partition_key_paths = ["/sessionId"]
}

# Shared eval results container.
resource "azurerm_cosmosdb_sql_container" "eval_results" {
  name                = "eval-results"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.this.name
  database_name       = azurerm_cosmosdb_sql_database.workshop.name
  partition_key_paths = ["/run_id"]
}

# Diagnostics → LAW
resource "azurerm_monitor_diagnostic_setting" "search" {
  name                       = "diag-search"
  target_resource_id         = azurerm_search_service.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "OperationLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "cosmos" {
  name                       = "diag-cosmos"
  target_resource_id         = azurerm_cosmosdb_account.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "DataPlaneRequests"
  }

  enabled_metric {
    category = "Requests"
  }
}

output "key_vault_id" { value = azurerm_key_vault.this.id }
output "key_vault_uri" { value = azurerm_key_vault.this.vault_uri }
output "storage_account_name" { value = azurerm_storage_account.this.name }
output "storage_account_id" { value = azurerm_storage_account.this.id }
output "acr_id" { value = azurerm_container_registry.this.id }
output "acr_login_server" { value = azurerm_container_registry.this.login_server }
output "search_endpoint" { value = "https://${azurerm_search_service.this.name}.search.windows.net" }
output "search_id" { value = azurerm_search_service.this.id }
output "cosmos_endpoint" { value = azurerm_cosmosdb_account.this.endpoint }
output "cosmos_id" { value = azurerm_cosmosdb_account.this.id }
