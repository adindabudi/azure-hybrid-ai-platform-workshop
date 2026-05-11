variable "prefix" {
  description = "Short prefix used in resource names. Lowercase, 3-6 chars."
  type        = string
  default     = "aigw"

  validation {
    condition     = can(regex("^[a-z]{3,6}$", var.prefix))
    error_message = "prefix must be 3-6 lowercase letters."
  }
}

variable "environment" {
  description = "Environment tag. workshop|dev|test."
  type        = string
  default     = "workshop"
}

variable "resource_group_name" {
  description = "Existing resource group name (created out-of-band by az group create)."
  type        = string
  default     = "rg-aigw-workshop"
}

variable "location" {
  description = "Primary region (Indonesia Central)."
  type        = string
  default     = "indonesiacentral"
}

variable "location_aoai" {
  description = "Region for Azure OpenAI deployments (Southeast Asia / Singapore — AOAI not available in IDC)."
  type        = string
  default     = "southeastasia"
}

variable "attendee_count" {
  description = "Number of workshop attendees. Set to 1 for the worst-case presenter-only run."
  type        = number
  default     = 10

  validation {
    condition     = var.attendee_count >= 1 && var.attendee_count <= 30
    error_message = "attendee_count must be between 1 and 30."
  }
}

variable "apim_publisher_name" {
  description = "Publisher name shown on the APIM developer portal. Visible to anyone with portal access — keep it neutral."
  type        = string
  default     = "Hybrid AI Platform Workshop"
}

variable "apim_publisher_email" {
  description = "Publisher email; receives notifications from APIM. The placeholder in workshop.tfvars works for unattended deploys; override with your real ops contact for production."
  type        = string
}

variable "aks_node_count" {
  description = "AKS system node count. 2 is enough for the workshop."
  type        = number
  default     = 2
}

variable "aks_node_vm_size" {
  description = "AKS VM size. D4s_v5 = 4 vCPU / 16 GiB."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "enable_cilium" {
  description = "Switch AKS network data plane to Cilium. Set false on the first apply (enables Overlay only), then true on the second apply. New-cluster greenfield deploys can start at true."
  type        = bool
  default     = false
}

variable "aoai_gpt_4o_mini_capacity" {
  description = "AOAI primary chat deployment capacity in 1K-TPM units. Defaults assume the workshop's `gpt-5-mini` GlobalStandard deployment; bump for higher throughput, or swap to gpt-4o-mini / gpt-4.1-mini in your fork."
  type        = number
  default     = 50 # = 50K TPM
}

variable "aoai_embedding_capacity" {
  description = "AOAI text-embedding-3-large deployment capacity in 1K-TPM units (text-embedding-3-small not in SEA)."
  type        = number
  default     = 50
}

variable "common_tags" {
  description = "Tags applied to every resource. Override or extend per workshop run."
  type        = map(string)
  default = {
    purpose     = "hybrid-ai-platform-workshop"
    cost-center = "hybrid-ai-workshop"
    deployed-by = "terraform"
    repo        = "hybrid-ai-platform-workshop"
  }
}
