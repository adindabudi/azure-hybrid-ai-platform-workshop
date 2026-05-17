# `infra/modules/foundry-project/` — Microsoft Foundry account + project

Provides the cloud Foundry workspace that the eval suite needs for the
**cloud-mode** RedTeam scan and the FoundryEvals cloud view.

Specifically required by:

- [`apps/eval-suite/redteam.py`](../../../apps/eval-suite/redteam.py) — calls
  `azure.ai.evaluation.red_team.RedTeam(azure_ai_project=…)`. The class's
  `_get_service_discovery_url()` constructor call hits the RAI service via
  the Foundry workspace **even in local-scan mode** — you cannot run
  `RedTeam.scan()` without a real Foundry project.
- [`apps/eval-suite/run_foundry_evals.py`](../../../apps/eval-suite/run_foundry_evals.py)
  — opt-in cloud view of the standalone evaluator output, when
  `agent_framework_azure_ai.FoundryEvals` is used.

## Why this is a separate, opt-in module

Off by default because:

1. Region-locked to one of **five** RedTeam-supported regions: `eastus2`,
   `francecentral`, `swedencentral`, `switzerlandwest`, `northcentralus`.
   The workshop's primary region is `indonesiacentral`, so this module always
   provisions cross-region with the `azurerm.foundry` provider alias.
2. Adds a small `gpt-5-mini` deployment (~10 1K-TPM units) on the Foundry
   account so the eval suite has a model to call.
3. The non-eval portions of the workshop (M0–M4, M6) don't depend on this.

## Enable

In your tfvars:

```hcl
enable_foundry_project        = true
location_foundry              = "eastus2"  # optional override
foundry_deploy_gpt_for_evals  = true       # optional, default true
foundry_evals_capacity        = 10         # optional, default 10
```

Then:

```bash
terraform apply \
  -var-file=env/workshop.tfvars \
  -var="apim_publisher_email=you@yourcompany.com" \
  -var="enable_foundry_project=true"
```

## What gets created

| Resource | Notes |
|----------|-------|
| `azurerm_cognitive_account.foundry` | `kind = "AIServices"`, `project_management_enabled = true`, `custom_subdomain_name`, SystemAssigned identity. This is the modern Foundry "account" resource. |
| `azurerm_cognitive_account_project.project` | Foundry **project** under the account. Carries `display_name` + `description` + its own SystemAssigned identity. |
| `azurerm_cognitive_deployment.evals_gpt` *(count-gated)* | Small `gpt-5-mini` deployment on the Foundry account for the eval suite. Skip with `foundry_deploy_gpt_for_evals = false`. |

## Modern pattern, NOT the legacy hub-classic

The old `azurerm_ai_foundry` resource (Hub-classic) is **deprecated** — its own
docs say "use `cognitive_account` instead". This module uses the modern path:

```hcl
resource "azurerm_cognitive_account" "foundry" {
  kind                       = "AIServices"
  sku_name                   = "S0"
  project_management_enabled = true
  custom_subdomain_name      = local.name.foundry
  identity { type = "SystemAssigned" }
}

resource "azurerm_cognitive_account_project" "project" {
  cognitive_account_id = azurerm_cognitive_account.foundry.id
  display_name         = "..."
  identity { type = "SystemAssigned" }
}
```

## Outputs

| Output | Use |
|--------|-----|
| `account_name`, `account_endpoint` | Direct AIServices endpoint for non-Foundry SDK calls |
| `project_id`, `project_name`, `project_endpoints` | Foundry project handles for SDKs that take a project id |
| `evals_deployment_name` | Pass to `OpenAIChatClient(model=…)` when targeting Foundry directly |
| `azure_ai_project` | **Pre-shaped descriptor** for the `azure_ai_project=` kwarg in `RedTeam(…)` and `FoundryEvals(…)`. Contains `{subscription_id, resource_group_name, project_name, account_name, endpoint}` — exactly what the SDKs want. |

All outputs are `null` when `enable_foundry_project = false`, so consumers
can `try(module.foundry_project[0].azure_ai_project, null)` and fall back to
the standalone (non-Foundry) code path.

## Notes

- The modern Foundry surface is `azurerm_cognitive_account` (kind = `AIServices`) +
  `azurerm_cognitive_account_project`. The older `azurerm_machine_learning_workspace`
  / `azurerm_ai_*` resources do not produce a project the v2 SDKs accept.
- The `RedTeam` class needs the **project** handle, not just the account, and
  reaches out to the RAI service via the project's region. Use one of the 5
  RedTeam-supported regions or `RedTeam.__init__` fails with `KeyError: 'properties'`.
