---
title: Provision the landing zone
sidebar_position: 2
---

# Provision the landing zone

The first thing the facilitator does, ideally the day before the
workshop. Plan for ~30 minutes wall-clock (APIM Developer is the long
pole).

## Prerequisites

```bash
terraform -version      # ≥ 1.9
az version              # ≥ 2.61
kubectl version --client | head -1
jq --version
```

Sign in to the subscription that will host the workshop:

```bash
az login
az account set --subscription <subscription-id>
az account show --query "{name:name, sub:id, tenant:tenantId}" -o table
```

You need **Owner** or **Contributor + Role Based Access Control
Administrator** on the workshop resource group (or the subscription).
The second role is the modern, scope-limited grant for
`Microsoft.Authorization/roleAssignments/write` — use it instead of
Owner so attendees can't escalate each other later
([reference](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles#role-based-access-control-administrator)).

## Step 1 — Create the resource group out-of-band

We create the RG outside Terraform so `terraform destroy` cannot cascade
into it.

```bash
az group create -n rg-aigw-workshop -l indonesiacentral
```

Change name/region as needed for your fork.

## Step 2 — Set the publisher email

APIM requires a publisher email. Override it on the CLI so it's not in
git:

```bash
export TF_VAR_apim_publisher_email="you@yourdomain.com"
```

Optionally edit
[`infra/env/workshop.tfvars`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/blob/main/infra/env/workshop.tfvars)
for `attendee_count`, `location`, `aoai_*_capacity`.

## Step 3 — Apply

```bash
cd infra
terraform init
terraform plan -var-file=env/workshop.tfvars -out=tf.plan
terraform apply tf.plan
```

First apply takes ~25–30 minutes. **AKS Cilium activation** is a two-step
migration on any existing `azure`-plugin cluster: leave `enable_cilium =
false` for the first apply, flip to `true` for the second. Greenfield
deploys can start at `true`.

## Step 4 — Smoke-test

```bash
./scripts/smoke-test.sh
```

Expected — all green:

```
✓ Resource group rg-aigw-workshop present
✓ APIM apim-aigw-<suffix> (state=Succeeded)
✓ AKS aks-aigw-<suffix> (state=Succeeded)
✓ AOAI endpoint https://aoai-aigw-sea-<suffix>.openai.azure.com reachable
✓ Attendee namespaces: 0 / 10        # zero is fine until you bootstrap
✓ Cilium running (3 pods in kube-system)
✓ Key Vault CSI driver running (6 pods)
```

If any check fails, fix before continuing to attendee provisioning.

## What got deployed

See [`infra/`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/tree/main/infra)
for the Terraform code. The headline resources:

| Component | Region | Notes |
| --- | --- | --- |
| APIM Developer (classic) | Primary | Long-pole resource, ~25 min |
| AKS w/ Cilium + Azure Linux | Primary | Workload identity + OIDC + KV CSI |
| AOAI account + `gpt-5-mini` + `text-embedding-3-large` | AOAI region | Cross-region from primary |
| Cosmos DB, AI Search Basic, KV, Storage, ACR | Primary | Workshop data plane |
| Log Analytics + Application Insights | Primary | Telemetry sink |

## Tear-down

After the workshop, destroy everything except the RG itself:

```bash
cd infra
terraform destroy -var-file=env/workshop.tfvars
```

This takes ~15 minutes (APIM Developer is again the long pole). The RG
remains so you can re-apply later without touching `az group create`.

## Next

[Provision attendees](./attendees.md)
