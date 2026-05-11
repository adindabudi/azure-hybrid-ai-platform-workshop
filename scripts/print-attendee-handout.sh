#!/usr/bin/env bash
# Print connection details for a single attendee. Sensitive — do NOT email.
#
# FACILITATOR-ONLY — requires Terraform state (reads `terraform output`).
# Attendees do not run this script; they receive its printed output.
#
# Usage: ./scripts/print-attendee-handout.sh 03

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <attendee-number>" >&2
  echo "  e.g. $0 03" >&2
  exit 1
fi

# 10# forces base-10 so leading zeros (08, 09) aren't parsed as invalid octal.
NUM=$(printf "%02d" "$((10#$1))")
NS="attendee-${NUM}"

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../infra" && pwd)"
cd "$INFRA_DIR"

RG=$(terraform output -raw resource_group_name)
AKS=$(terraform output -raw aks_name)
APIM=$(terraform output -raw apim_name)
APIM_GATEWAY=$(terraform output -raw apim_gateway_url)
APIM_PORTAL=$(terraform output -raw apim_developer_portal_url)
KV_URI=$(terraform output -raw key_vault_uri)
AOAI_ENDPOINT=$(terraform output -raw aoai_endpoint)
GPT_DEPLOY=$(terraform output -raw aoai_gpt_4o_mini_deployment)
EMB_DEPLOY=$(terraform output -raw aoai_embedding_deployment)
COSMOS=$(terraform output -raw cosmos_endpoint)
SEARCH=$(terraform output -raw search_endpoint)
APPI_CONN=$(terraform output -raw application_insights_connection_string)

APIM_KEY=$(az apim subscription show \
  --resource-group "$RG" --service-name "$APIM" \
  --sid "${NS}" --query primaryKey -o tsv 2>/dev/null \
  || az rest --method post \
      --url "$(terraform output -json attendee_handout | jq -r ".\"$NS\".apim_subscription_id")/listSecrets?api-version=2022-08-01" \
      --query primaryKey -o tsv)

cat <<HANDOUT
=================================================================
   AI GATEWAY WORKSHOP — Connection details for ${NS}
=================================================================

== Step 0: WSL users — install az INSIDE WSL (not the Windows MSI) ==
  which az kubectl    # both should end in /usr/bin/  (or both .exe)
  # If "az" is .exe but "kubectl" isn't, run:
  #   curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash && hash -r
  # Otherwise az.exe writes kubeconfig to C:\\Users\\you\\.kube\\config
  # and your Linux kubectl will see "no current context is set".

== Step 1: Get AKS credentials (creates your kubectl context) ==
  az login
  az account set --subscription <subscription-id>
  az aks get-credentials -g ${RG} -n ${AKS} --overwrite-existing
  kubectl config current-context     # must print ${AKS}

== Step 2: Pin your namespace as the default ==
  kubectl config set-context --current --namespace=${NS}
  kubectl get all          # should be empty initially
  # If you see "error: no current context is set" — re-read Step 0.

== APIM ==
  Gateway URL              : ${APIM_GATEWAY}
  Developer portal         : ${APIM_PORTAL}
  Subscription key (header): Ocp-Apim-Subscription-Key: ${APIM_KEY:-<run scripts/bootstrap-attendees.sh first>}

== Backends fronted by APIM ==
  AOAI endpoint            : ${AOAI_ENDPOINT}
    deployments            : ${GPT_DEPLOY} (chat), ${EMB_DEPLOY} (embedding)
  Self-hosted SLM          : (deployed by M1 lab; APIM backend "slm-phi4")

== Data stores (workshop-shared) ==
  Cosmos DB                : ${COSMOS}
    your container         : state-${NS}  (partition key: /sessionId)
  AI Search                : ${SEARCH}
  Key Vault                : ${KV_URI}

== Observability ==
  App Insights conn string : (sensitive — pull at runtime)
    \$ terraform output -raw application_insights_connection_string

== APIM curl smoke-test ==
  curl -s "${APIM_GATEWAY}/openai/deployments/${GPT_DEPLOY}/chat/completions?api-version=2024-10-21" \\
    -H "Ocp-Apim-Subscription-Key: ${APIM_KEY:-<key>}" \\
    -H "Content-Type: application/json" \\
    -d '{"messages":[{"role":"user","content":"hello, what region am I talking to?"}]}'

== Verify your policies (no Terraform state needed) ==
  export APIM_GATEWAY_URL="${APIM_GATEWAY}"
  export APIM_KEY="${APIM_KEY:-<key>}"
  ./scripts/verify-policies.sh         # after M1
  ./scripts/verify-policies.sh --m2    # after M2

=================================================================
HANDOUT
