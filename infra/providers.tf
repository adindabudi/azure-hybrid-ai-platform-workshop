terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.54"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.7"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  # Tenant policy disables shared-key auth on storage. Force provider to use
  # AAD for all storage data-plane operations (state reads + container provisioning).
  storage_use_azuread = true

  features {
    key_vault {
      purge_soft_delete_on_destroy               = true
      purge_soft_deleted_keys_on_destroy         = true
      purge_soft_deleted_secrets_on_destroy      = true
      purge_soft_deleted_certificates_on_destroy = true
      recover_soft_deleted_key_vaults            = true
    }
    resource_group {
      # workshop RG is created out-of-band; never let TF cascade-delete it
      prevent_deletion_if_contains_resources = true
    }
    cognitive_account {
      purge_soft_delete_on_destroy = true
    }
  }
}

# Provider alias for cross-region AOAI in Singapore (SEA).
# AOAI/AI Foundry/Content Safety are NOT available in IDC — see workshop plan §1.2.
provider "azurerm" {
  alias               = "sea"
  storage_use_azuread = true

  features {
    cognitive_account {
      purge_soft_delete_on_destroy = true
    }
  }
}

provider "azapi" {}
