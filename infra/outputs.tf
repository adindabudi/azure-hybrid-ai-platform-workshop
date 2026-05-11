output "resource_group_name" {
  value = data.azurerm_resource_group.workshop.name
}

output "location" {
  value = var.location
}

output "vnet_id" {
  value = module.networking.vnet_id
}

# --- APIM ---
output "apim_name" {
  value = module.apim.apim_name
}

output "apim_gateway_url" {
  value = module.apim.gateway_url
}

output "apim_developer_portal_url" {
  value = module.apim.developer_portal_url
}

output "apim_management_url" {
  value = module.apim.management_url
}

# --- AKS ---
output "aks_name" {
  value = module.aks.aks_name
}

output "aks_cluster_id" {
  value = module.aks.cluster_id
}

output "aks_kubelet_identity_object_id" {
  value = module.aks.kubelet_identity_object_id
}

output "aks_oidc_issuer_url" {
  value = module.aks.oidc_issuer_url
}

# --- Data plane ---
output "key_vault_uri" {
  value = module.data.key_vault_uri
}

output "storage_account_name" {
  value = module.data.storage_account_name
}

output "acr_login_server" {
  value = module.data.acr_login_server
}

output "search_endpoint" {
  value = module.data.search_endpoint
}

output "cosmos_endpoint" {
  value = module.data.cosmos_endpoint
}

# --- Observability ---
output "application_insights_connection_string" {
  value     = module.observability.application_insights_connection_string
  sensitive = true
}

output "log_analytics_workspace_id" {
  value = module.observability.log_analytics_workspace_id
}

# --- AOAI Singapore ---
output "aoai_endpoint" {
  value = module.aoai_singapore.endpoint
}

output "aoai_gpt_4o_mini_deployment" {
  value = module.aoai_singapore.gpt_4o_mini_deployment_name
}

output "aoai_embedding_deployment" {
  value = module.aoai_singapore.embedding_deployment_name
}

output "content_safety_endpoint" {
  value = module.aoai_singapore.content_safety_endpoint
}

# --- Attendee handout ---
output "attendees" {
  description = "List of attendee namespace identifiers."
  value       = [for a in module.aks.attendee_namespaces : a]
}

output "attendee_handout" {
  description = "Per-attendee connection info. Sensitive — do not commit."
  sensitive   = true
  value = {
    for idx, name in [for a in module.aks.attendee_namespaces : a] :
    name => {
      namespace                = name
      apim_subscription_id     = module.apim.attendee_subscriptions[name].id
      aks_kubeconfig_command   = "az aks get-credentials -g ${data.azurerm_resource_group.workshop.name} -n ${module.aks.aks_name} --overwrite-existing"
      gateway_url              = module.apim.gateway_url
      app_insights_conn_string = module.observability.application_insights_connection_string
    }
  }
}
