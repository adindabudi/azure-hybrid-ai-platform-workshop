terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.54"
    }
  }
}

variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "aks_name" { type = string }
variable "node_count" { type = number }
variable "node_vm_size" { type = string }
variable "attendees" { type = list(string) }
variable "log_analytics_workspace_id" { type = string }
variable "acr_id" { type = string }
variable "key_vault_id" { type = string }
variable "tags" { type = map(string) }
variable "enable_cilium" {
  description = "Switch network data plane to Cilium. Must be false on the first apply of an existing classic azure-plugin cluster (overlay mode is enabled first), then set to true and re-applied. New clusters can set true immediately."
  type        = bool
  default     = false
}

# ============================================================================
# AKS — production-aligned posture for the workshop
# Per Microsoft baseline + microservices reference architecture (May 2026):
#   - Azure Linux node OS (lighter, hardened, faster boot)
#   - Azure CNI Powered by Cilium (eBPF, native L3-L7 NetworkPolicy)
#   - Workload Identity + OIDC issuer
#   - Azure Key Vault Secrets Provider CSI add-on
#
# Sources:
#   https://learn.microsoft.com/azure/aks/azure-cni-powered-by-cilium
#   https://learn.microsoft.com/azure/architecture/reference-architectures/containers/aks-microservices/aks-microservices-advanced
#   https://learn.microsoft.com/azure/architecture/reference-architectures/containers/aks/baseline-aks
#   https://learn.microsoft.com/azure/aks/csi-secrets-store-identity-access
# ============================================================================

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.aks_name
  resource_group_name = var.resource_group_name
  location            = var.location
  dns_prefix          = "aigw"
  sku_tier            = "Free"
  tags                = var.tags

  oidc_issuer_enabled       = true
  workload_identity_enabled = true
  local_account_disabled    = false
  azure_policy_enabled      = false

  default_node_pool {
    name            = "system"
    node_count      = var.node_count
    vm_size         = var.node_vm_size
    os_sku          = "AzureLinux"
    os_disk_size_gb = 64
    # Ephemeral OS disk requires a VM SKU with local temp storage. D4s_v5 has none —
    # use D4ds_v5 or Ds_v5+managed. We default to managed for max SKU portability;
    # change to "Ephemeral" if you switch to a ds-suffixed SKU.
    os_disk_type                 = "Managed"
    type                         = "VirtualMachineScaleSets"
    auto_scaling_enabled         = false
    only_critical_addons_enabled = false
    upgrade_settings {
      max_surge = "33%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  # AKS does NOT allow enabling Overlay and Cilium dataplane in the same
  # update operation (Azure API rejects with 400 MustEnableAzureCNIOverlay
  # BeforeEnablingCilium). For an existing classic azure-plugin cluster a
  # two-step migration is required:
  #   Step 1 (this apply): switch to overlay mode + pod_cidr (dataplane stays "azure")
  #   Step 2 (next apply): switch network_data_plane to "cilium" and network_policy to "cilium"
  # The `var.enable_cilium` toggle below controls the second step.
  # New clusters created from scratch can set both in one go.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = var.enable_cilium ? "cilium" : "azure"
    network_policy      = var.enable_cilium ? "cilium" : "azure"
    pod_cidr            = "192.168.0.0/16"
    service_cidr        = "10.41.0.0/16"
    dns_service_ip      = "10.41.0.10"
    load_balancer_sku   = "standard"
  }

  oms_agent {
    log_analytics_workspace_id = var.log_analytics_workspace_id
  }

  monitor_metrics {}

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count,
    ]
  }
}

resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

resource "azurerm_user_assigned_identity" "attendee" {
  for_each = toset(var.attendees)

  name                = "uami-${each.value}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "attendee" {
  for_each = toset(var.attendees)

  name                = "fed-${each.value}"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.attendee[each.value].id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject             = "system:serviceaccount:${each.value}:agent-sa"
}

resource "azurerm_role_assignment" "attendee_kv_secrets" {
  for_each = toset(var.attendees)

  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.attendee[each.value].principal_id
}

output "aks_name" { value = azurerm_kubernetes_cluster.this.name }
output "cluster_id" { value = azurerm_kubernetes_cluster.this.id }
output "kubelet_identity_object_id" { value = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id }
output "oidc_issuer_url" { value = azurerm_kubernetes_cluster.this.oidc_issuer_url }
output "attendee_namespaces" { value = var.attendees }
output "attendee_uami_client_ids" {
  value = { for name in var.attendees : name => azurerm_user_assigned_identity.attendee[name].client_id }
}
output "attendee_uami_principal_ids" {
  value = { for name in var.attendees : name => azurerm_user_assigned_identity.attendee[name].principal_id }
}
output "key_vault_secrets_provider_object_id" {
  value = azurerm_kubernetes_cluster.this.key_vault_secrets_provider[0].secret_identity[0].object_id
}
