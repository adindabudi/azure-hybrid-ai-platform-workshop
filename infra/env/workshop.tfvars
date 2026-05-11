# ---------------------------------------------------------------------------
# Hybrid AI Platform Workshop — sample tfvars
#
# This file is checked into the repo and is intentionally non-sensitive.
# Override the `apim_publisher_email` (REQUIRED by Azure APIM) and any
# other values for your own workshop run via:
#
#   terraform apply \
#     -var-file=env/workshop.tfvars \
#     -var="apim_publisher_email=you@yourdomain.com"
#
# ---------------------------------------------------------------------------

prefix      = "aigw"
environment = "workshop"

# The RG is created out-of-band so `terraform destroy` does not cascade
# into it. Change to whatever you used in `az group create`.
resource_group_name = "rg-aigw-workshop"

# Primary region. Indonesia Central is the workshop's canonical example
# (partial Azure coverage — the workshop's whole pedagogy). Change to
# `westeurope`, `eastus`, etc. for a region with full coverage.
location = "indonesiacentral"

# Region used for the services that are not yet in `location`. Set this
# equal to `location` if your primary region has full coverage.
location_aoai = "southeastasia"

# Per-attendee resources are minted by the `aks`, `apim`, `data` modules.
# Set to 1 for a presenter-only worst-case dry run.
attendee_count = 10

apim_publisher_name = "Hybrid AI Platform Workshop"

# REQUIRED by Azure APIM, but visible in the developer portal. The
# placeholder below lets `terraform plan` succeed for a dry run; override
# on the command line for any real deploy.
apim_publisher_email = "workshop-facilitator@example.invalid"

aks_node_count   = 2
aks_node_vm_size = "Standard_D4s_v5"

# AOAI capacity (1K-TPM units). The workshop uses gpt-5-mini and
# text-embedding-3-large by default; both are well within the free
# quotas on most Internal subscriptions. Adjust per your sub.
aoai_gpt_4o_mini_capacity = 50
aoai_embedding_capacity   = 50
