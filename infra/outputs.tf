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

output "content_safety_name" {
  description = "Content Safety account name (used by scripts/apply-apim-policies.sh --with-content-safety). Empty string when the workshop is deployed with deploy_content_safety=false."
  value       = module.aoai_singapore.content_safety_name
}

# --- Foundry project (opt-in) ---
# All values are `null` when enable_foundry_project = false. Consumers
# (apps/eval-suite/redteam.py, run_foundry_evals.py) should check for null
# and fall back to the standalone (non-Foundry) code path.
output "foundry_account_name" {
  description = "Microsoft Foundry (AIServices) account name. Null when the module is disabled."
  value       = try(module.foundry_project[0].account_name, null)
}

output "foundry_account_endpoint" {
  description = "Foundry account endpoint (https://<name>.cognitiveservices.azure.com/openai/). Null when disabled."
  value       = try(module.foundry_project[0].account_endpoint, null)
}

output "foundry_project_id" {
  description = "Foundry project resource ID. Null when disabled."
  value       = try(module.foundry_project[0].project_id, null)
}

output "foundry_project_name" {
  description = "Foundry project name. Null when disabled."
  value       = try(module.foundry_project[0].project_name, null)
}

output "foundry_project_endpoints" {
  description = "Map of endpoint name → URL exposed by the Foundry project. Null when disabled."
  value       = try(module.foundry_project[0].project_endpoints, null)
}

output "foundry_evals_deployment_name" {
  description = "Name of the gpt-* deployment on the Foundry account, used by the eval suite. Null/empty when disabled or when foundry_deploy_gpt_for_evals = false."
  value       = try(module.foundry_project[0].evals_deployment_name, null)
}

output "foundry_azure_ai_project" {
  description = "Pre-shaped descriptor for `azure_ai_project=` kwarg in RedTeam / FoundryEvals (subscription_id, resource_group_name, project_name, account_name, endpoint). Null when disabled."
  value       = try(module.foundry_project[0].azure_ai_project, null)
}

# --- Managed Redis (opt-in semantic cache) ---
# All values are `null` when enable_semantic_cache = false.
# scripts/verify-policies.sh checks `apim_external_cache_id` to decide
# whether Step 4 should run the cache test or yellow-skip it.
output "managed_redis_id" {
  description = "Full resource ID of the Managed Redis cluster. Null when disabled."
  value       = try(module.managed_redis[0].redis_id, null)
}

output "managed_redis_hostname" {
  description = "DNS hostname of the Managed Redis cluster. Null when disabled."
  value       = try(module.managed_redis[0].redis_hostname, null)
}

output "apim_external_cache_id" {
  description = "Full resource ID of the APIM Redis Cache binding. Presence of this output is what enables semantic-cache policies to actually hit Redis. Null when the module is disabled."
  value       = try(module.managed_redis[0].apim_external_cache_id, null)
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
