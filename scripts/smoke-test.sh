#!/usr/bin/env bash
# Quick smoke test of the deployed landing zone — facilitator runs this the
# morning of the workshop to confirm everything is reachable.
#
# FACILITATOR-ONLY — requires Terraform state and RG reader permissions.
# Attendees use scripts/verify-policies.sh (env-var driven) instead.

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../infra" && pwd)"
cd "$INFRA_DIR"

green()  { printf '\033[32m✓\033[0m %s\n' "$1"; }
red()    { printf '\033[31m✗\033[0m %s\n' "$1"; }
yellow() { printf '\033[33m!\033[0m %s\n' "$1"; }

RG=$(terraform output -raw resource_group_name)
AKS=$(terraform output -raw aks_name)
APIM=$(terraform output -raw apim_name)
APIM_GW=$(terraform output -raw apim_gateway_url)

# 1. RG present
if az group show -n "$RG" >/dev/null 2>&1; then
  green "Resource group $RG present"
else
  red "Resource group $RG missing"
  exit 1
fi

# 2. APIM running
APIM_STATE=$(az apim show -g "$RG" -n "$APIM" --query provisioningState -o tsv 2>/dev/null || echo "absent")
if [[ "$APIM_STATE" == "Succeeded" ]]; then
  green "APIM $APIM (state=$APIM_STATE)"
else
  red "APIM not ready (state=$APIM_STATE)"
fi

# 3. AKS reachable
AKS_STATE=$(az aks show -g "$RG" -n "$AKS" --query provisioningState -o tsv 2>/dev/null || echo "absent")
if [[ "$AKS_STATE" == "Succeeded" ]]; then
  green "AKS $AKS (state=$AKS_STATE)"
else
  red "AKS not ready (state=$AKS_STATE)"
fi

# 4. AOAI endpoint reachable
AOAI=$(terraform output -raw aoai_endpoint)
if curl -fsS "$AOAI" -o /dev/null --connect-timeout 5 >/dev/null 2>&1; then
  green "AOAI endpoint $AOAI reachable"
else
  yellow "AOAI endpoint not 200 yet (expected without auth)"
fi

# 5. APIM gateway reachable
if curl -fsS "$APIM_GW/internal-status-0123456789abcdef" -o /dev/null --connect-timeout 5 >/dev/null 2>&1; then
  green "APIM gateway $APIM_GW reachable"
else
  yellow "APIM gateway 401/404 (normal for an unauthed probe)"
fi

# 6. Attendee namespaces — must match attendee_count AND be fully bootstrapped.
EXPECTED=$(terraform output -json attendee_handout 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
NS_COUNT=$(kubectl get ns -o name 2>/dev/null | grep -c '^namespace/attendee-' || echo 0)

if (( NS_COUNT == 0 )); then
  red "Attendee namespaces: 0 / $EXPECTED — run ./scripts/bootstrap-attendees.sh"
elif (( NS_COUNT != EXPECTED )); then
  red "Attendee namespaces: $NS_COUNT / $EXPECTED — re-run ./scripts/bootstrap-attendees.sh"
else
  # Spot-check the first attendee actually has agent-sa + apim-credentials + SPC.
  FIRST_NS=$(kubectl get ns -o name 2>/dev/null | grep '^namespace/attendee-' | sort | head -1 | sed 's|namespace/||')
  MISSING=()
  kubectl get sa agent-sa -n "$FIRST_NS" >/dev/null 2>&1 || MISSING+=("sa/agent-sa")
  kubectl get secret apim-credentials -n "$FIRST_NS" >/dev/null 2>&1 || MISSING+=("secret/apim-credentials")
  kubectl get secretproviderclass azure-kv-shared -n "$FIRST_NS" >/dev/null 2>&1 || MISSING+=("spc/azure-kv-shared")
  if (( ${#MISSING[@]} == 0 )); then
    green "Attendee namespaces: $NS_COUNT / $EXPECTED (spot-check $FIRST_NS: agent-sa, apim-credentials, azure-kv-shared all present)"
  else
    red "Attendee namespaces: $NS_COUNT / $EXPECTED present, but $FIRST_NS missing: ${MISSING[*]} — re-run ./scripts/bootstrap-attendees.sh"
  fi
fi

# 7. Cilium pods
CILIUM_PODS=$(kubectl get pods -n kube-system -l k8s-app=cilium -o name 2>/dev/null | wc -l)
if (( CILIUM_PODS > 0 )); then
  green "Cilium running ($CILIUM_PODS pods in kube-system)"
else
  red "Cilium pods missing — verify network_data_plane setting"
fi

# 8. KV CSI driver pods
CSI_PODS=$(kubectl get pods -n kube-system -l app=secrets-store-csi-driver -o name 2>/dev/null | wc -l)
if (( CSI_PODS > 0 )); then
  green "Key Vault CSI driver running ($CSI_PODS pods)"
else
  red "KV CSI driver pods missing"
fi

echo ""
echo "Smoke test complete."
