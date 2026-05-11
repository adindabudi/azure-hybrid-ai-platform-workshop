#!/usr/bin/env bash
# Reset a single attendee namespace back to pristine state.
#
# FACILITATOR-ONLY — requires AKS admin / cluster role on attendee namespaces.
# Does NOT require Terraform state.
#
# Usage: ./scripts/reset-attendee.sh 03

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <attendee-number>" >&2
  exit 1
fi

NUM=$(printf "%02d" "$1")
NS="attendee-${NUM}"

echo "==> Deleting all workshop workloads in $NS (keeps SA/quota/SPC)..."
kubectl -n "$NS" delete deploy,statefulset,svc,ingress,job,cronjob --all --ignore-not-found

echo "==> Done. Run scripts/bootstrap-attendees.sh to re-seed if needed."
