# Content Safety container — in-region deployment

> **Why this is a manifest, not Terraform.** The Content Safety container is
> **public preview**, **billing-metered** (phones home every 10–15 min to a
> Content Safety **resource** in your sub), and the standard container
> **requires a Standard (S0) Content Safety resource** for billing. Many
> Internal / trial subscriptions don't have the Content Safety entitlement,
> so the container can't activate against them.
>
> **In a paid customer subscription** (which is the actual production path
> for any in-region / in-country data residency requirement): create one
> Content Safety **S0 resource in the closest available Azure region**
> purely for billing, then run the container on AKS in your **primary**
> region — all prompt/response traffic stays in-region; only the
> lightweight billing heartbeat egresses. This is the Microsoft-documented
> pattern for in-region data residency with managed-billing entitlement
> (see [container overview](https://learn.microsoft.com/azure/ai-services/content-safety/how-to/containers/install-run-container)).
>
> For full data residency (no billing heartbeat at all), submit the
> [disconnected containers request form](https://aka.ms/csdisconnectedcontainers)
> and purchase a commitment plan.

## Container metadata (verified May 2026)

| Fact | Value | Source |
|---|---|---|
| Image | `mcr.microsoft.com/azure-cognitive-services/contentsafety/text-analyze:latest` | [container overview](https://learn.microsoft.com/azure/ai-services/content-safety/how-to/containers/container-overview) |
| Architecture | amd64 only — no arm64 manifest | `docker manifest inspect` |
| Size | 8.79 GB compressed / 25.5 GB on disk | `docker inspect` |
| NVIDIA driver pin | `cuda>=11.8 brand=tesla,driver>=470,driver<471` | `docker inspect` env `NVIDIA_REQUIRE_CUDA` |
| Port | 5000 (HTTP) | `docker inspect` `ExposedPorts` |
| Billing | every 10–15 min to CS S0 resource; stops serving after 10 failed attempts | [billing docs](https://learn.microsoft.com/azure/ai-services/content-safety/how-to/containers/install-run-container#billing-information) |
| Tier required | **S0** on the linked CS resource (F0 not supported) | [prerequisites](https://learn.microsoft.com/azure/ai-services/content-safety/how-to/containers/install-run-container#prerequisites) |

## Two paths to deploy (pick one)

### Path A — GPU node pool (production recommended)

A GPU is **mandatory for production**. `CUDA_ENABLED=false` is documented as
testing only.

```bash
# Add a small GPU node pool to the workshop AKS
az aks nodepool add \
  --resource-group rg-aigw-workshop \
  --cluster-name $(terraform -chdir=infra output -raw aks_name) \
  --name csgpu \
  --node-count 1 \
  --node-vm-size Standard_NC4as_T4_v3 \
  --node-taints sku=gpu:NoSchedule \
  --labels workload=content-safety \
  --os-sku AzureLinux \
  --enable-cluster-autoscaler --min-count 0 --max-count 2

# Pre-pull the image (8.79 GB) so the first attendee request doesn't time out
kubectl create namespace content-safety
kubectl apply -n content-safety -f content-safety-prepull-daemonset.yaml
```

### Path B — CPU-only (workshop demo only)

```bash
kubectl create namespace content-safety
kubectl apply -n content-safety -f content-safety-cpu.yaml
```

## What `CUDA_ENABLED=false` actually means

Microsoft documents `CUDA_ENABLED=false` explicitly as **for testing only**.
It runs, returns valid responses, but at ~50–100× slower throughput than the
GPU path. Acceptable for a lab demo, **never** a recommendation for any real
production workflow.
