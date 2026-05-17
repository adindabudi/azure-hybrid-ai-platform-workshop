locals {
  # 4-char random suffix to keep globally unique resources unique across
  # multiple workshop runs (KV, Storage, ACR all need globally unique names).
  suffix = random_string.suffix.result

  # Naming building blocks (Cloud Adoption Framework abbreviations).
  name = {
    rg         = var.resource_group_name
    apim       = "apim-${var.prefix}-${local.suffix}"
    aks        = "aks-${var.prefix}-${local.suffix}"
    vnet       = "vnet-${var.prefix}-${local.suffix}"
    law        = "law-${var.prefix}-${local.suffix}"
    appi       = "appi-${var.prefix}-${local.suffix}"
    kv         = "kv${var.prefix}${local.suffix}"  # KV is restrictive: alphanumeric + dashes, max 24
    st         = "st${var.prefix}${local.suffix}"  # Storage: 3-24 lowercase alphanumeric
    acr        = "acr${var.prefix}${local.suffix}" # ACR: 5-50 alphanumeric
    srch       = "srch-${var.prefix}-${local.suffix}"
    cosmos     = "cosmos-${var.prefix}-${local.suffix}"
    aoai       = "aoai-${var.prefix}-sea-${local.suffix}"
    cog_safety = "cs-${var.prefix}-sea-${local.suffix}"
    foundry    = "aif${var.prefix}${local.suffix}"     # AIServices account; alphanumeric, 2-64
    foundry_pr = "prj-${var.prefix}-${local.suffix}"   # Foundry project under the account
    redis      = "redis-${var.prefix}-${local.suffix}" # Managed Redis cluster (3-63 chars, lowercase + dashes)
  }

  tags = merge(var.common_tags, {
    environment = var.environment
  })

  # Per-attendee identifiers (attendee-01 ... attendee-NN).
  attendees = [for i in range(1, var.attendee_count + 1) : format("attendee-%02d", i)]
}

resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
  numeric = true
}
