terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.54"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "apim_name" { type = string }
variable "publisher_name" { type = string }
variable "publisher_email" { type = string }
variable "log_analytics_workspace_id" { type = string }
variable "application_insights_id" { type = string }
variable "application_insights_instrumentation_key" {
  type      = string
  sensitive = true
}
variable "attendees" { type = list(string) }
variable "tags" { type = map(string) }

# ============================================================================
# Azure API Management — Developer (classic) in IDC
# Workshop only. Prod target = Premium classic IDC OR self-hosted gateway.
# Provision time ~25-30 min — start this FIRST in the apply.
# ============================================================================

resource "azurerm_api_management" "this" {
  name                = var.apim_name
  resource_group_name = var.resource_group_name
  location            = var.location
  publisher_name      = var.publisher_name
  publisher_email     = var.publisher_email
  sku_name            = "Developer_1"
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

# ----- Application Insights logger -----

resource "azurerm_api_management_logger" "appi" {
  name                = "appi-logger"
  api_management_name = azurerm_api_management.this.name
  resource_group_name = var.resource_group_name
  resource_id         = var.application_insights_id

  application_insights {
    instrumentation_key = var.application_insights_instrumentation_key
  }
}

# ----- Diagnostic settings (control-plane → LAW) -----

resource "azurerm_monitor_diagnostic_setting" "apim" {
  name                       = "diag-apim"
  target_resource_id         = azurerm_api_management.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "GatewayLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# ============================================================================
# Per-attendee subscriptions: one product + one subscription key per attendee.
# Lets us rate-limit and emit metrics dimensioned by attendee.
# ============================================================================

resource "azurerm_api_management_product" "attendee" {
  for_each = toset(var.attendees)

  product_id            = each.value
  api_management_name   = azurerm_api_management.this.name
  resource_group_name   = var.resource_group_name
  display_name          = "Workshop ${each.value}"
  description           = "Per-attendee product for namespace ${each.value}"
  subscription_required = true
  approval_required     = false
  published             = true
  subscriptions_limit   = 5
}

resource "azurerm_api_management_subscription" "attendee" {
  for_each = toset(var.attendees)

  api_management_name = azurerm_api_management.this.name
  resource_group_name = var.resource_group_name
  product_id          = azurerm_api_management_product.attendee[each.value].id
  display_name        = "sub-${each.value}"
  state               = "active"
  allow_tracing       = true
}

# ============================================================================
# Named values for backends (consumed by policy fragments)
# ============================================================================

resource "azurerm_api_management_named_value" "aoai_endpoint" {
  name                = "aoai-endpoint-sea"
  api_management_name = azurerm_api_management.this.name
  resource_group_name = var.resource_group_name
  display_name        = "aoai-endpoint-sea"
  value               = "https://placeholder-set-after-aoai-module-applies.openai.azure.com"
  # Overwritten by post-apply tooling (see `scripts/`) once the AOAI module
  # has emitted its endpoint output.
  secret = false
}

output "apim_id" { value = azurerm_api_management.this.id }
output "apim_name" { value = azurerm_api_management.this.name }
output "gateway_url" { value = azurerm_api_management.this.gateway_url }
output "developer_portal_url" { value = azurerm_api_management.this.developer_portal_url }
output "management_url" { value = azurerm_api_management.this.management_api_url }
output "principal_id" { value = azurerm_api_management.this.identity[0].principal_id }
output "attendee_subscriptions" {
  value = {
    for name in var.attendees : name => {
      id           = azurerm_api_management_subscription.attendee[name].id
      product_id   = azurerm_api_management_product.attendee[name].id
      display_name = azurerm_api_management_subscription.attendee[name].display_name
    }
  }
}
