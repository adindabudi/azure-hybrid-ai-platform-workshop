# Azure AI Language PII container — in-region deployment

> **Why this is a manifest, not Terraform.** Same reason as
> [apps/content-safety-cpu](../content-safety-cpu/README.md): the Azure AI
> Language container is **billing-metered** — it reaches an Azure Language
> S0 resource every 10–15 min for usage reporting, but no prompt or
> response text ever leaves the cluster. Many Internal / trial
> subscriptions don't have the Language entitlement, so we ship this as
> an **opt-in** manifest rather than baking it into Terraform.

This container is **optional**. The default workshop PII redactor
([apps/presidio-pii](../presidio-pii/README.md)) works on its own using
spaCy NER + Indonesian regex recognizers. Deploy this Language PII
container only when:

- You're running the BFSI production track and need higher recall on
  `Person`, `Address`, `IPAddress`, `IBAN`, `CreditCardNumber`, etc., or
- You're already a Language Service customer and want to reuse that
  entitlement instead of relying on spaCy alone.

When deployed, Presidio picks it up automatically through its
`AzureLanguagePiiRecognizer` `RemoteRecognizer` (see
[apps/presidio-pii/recognizers/text_analytics.py](../presidio-pii/recognizers/text_analytics.py)).

## Container metadata (verified May 2026)

| Fact | Value | Source |
|---|---|---|
| Image | `mcr.microsoft.com/azure-cognitive-services/textanalytics/pii:latest` | [container how-to](https://learn.microsoft.com/azure/ai-services/language-service/personally-identifiable-information/how-to/use-containers) |
| Architecture | amd64 only | MCR manifest |
| Port | 5000 (HTTP) | docs |
| Memory | minimum 8 GB per replica | [requirements](https://learn.microsoft.com/azure/ai-services/language-service/personally-identifiable-information/how-to/use-containers#run-the-container-with-docker-run) |
| Billing | every 10–15 min to a Language S0 resource; stops serving after 10 failed billing attempts | [billing docs](https://learn.microsoft.com/azure/ai-services/language-service/personally-identifiable-information/how-to/use-containers#billing) |
| Entitlement required | **S0** Language (Foundry Tools) resource — F0 is not eligible | [prerequisites](https://learn.microsoft.com/azure/ai-services/language-service/personally-identifiable-information/how-to/use-containers#prerequisites) |

## Two paths to deploy (pick one)

### Path A — Self-bake the image into the workshop ACR (recommended)

```bash
ACR_NAME=$(terraform -chdir=../../infra output -raw acr_name)

# Pull from MCR, push to your ACR (one-shot import, no Dockerfile needed)
az acr import \
  --name "$ACR_NAME" \
  --source mcr.microsoft.com/azure-cognitive-services/textanalytics/pii:latest \
  --image textanalytics-pii:latest
```

Then apply the manifest. Edit the placeholders in the `Secret` first.

```bash
# 1. Patch the billing endpoint + key into the Secret stanza, then:
kubectl apply -f language-pii-cpu.yaml

# 2. Wait for the Pod to become Ready (3–5 min — image is ~2 GB and
#    the model is loaded into memory once before /status returns 200)
kubectl rollout status -n language-pii deploy/language-pii
```

### Path B — Pull straight from MCR (no ACR step, more egress)

Edit `language-pii-cpu.yaml` and replace
`${ACR_LOGIN_SERVER}/textanalytics-pii:latest` with
`mcr.microsoft.com/azure-cognitive-services/textanalytics/pii:latest`.
Skip the `az acr import` step. AKS pulls directly from MCR; works if
your cluster has unrestricted egress.

## Wire it into Presidio

Once the Pod is `Ready`, give Presidio the endpoint:

```bash
kubectl create secret generic language-pii \
  -n presidio \
  --from-literal=LANGUAGE_ENDPOINT='http://language-pii.language-pii.svc.cluster.local:5000' \
  --from-literal=LANGUAGE_KEY='ignored-by-container-but-required-by-recognizer'

# Restart Presidio so it re-reads envFrom
kubectl rollout restart -n presidio deploy/presidio-pii
```

Verify Presidio registered the recognizer:

```bash
kubectl logs -n presidio deploy/presidio-pii | grep AzureLanguagePiiRecognizer
# Expected: AzureLanguagePiiRecognizer enabled → http://language-pii...:5000

curl -sS http://localhost:8080/supportedentities | jq .
# Expected to include: PERSON, ORGANIZATION, LOCATION, EMAIL_ADDRESS, ...
```

## End-to-end smoke test

```bash
kubectl port-forward -n presidio svc/presidio-pii 8080:80 &

curl -sS -X POST http://localhost:8080/redact \
  -H 'Content-Type: application/json' \
  -d '{"text":"Pak Budi tinggal di Jl. Sudirman No. 1, Jakarta. NIK 3171012345678901."}'
# Expect both PERSON-MASKED (from Language NER) AND NIK-MASKED (from
# Indonesian recognizer) in the redacted text.
```

## Disconnected mode (no internet egress at all)

For full data residency with no billing heartbeat, request a Language
disconnected-container commitment plan via the
[disconnected containers application form](https://aka.ms/csdisconnectedcontainers).
Once approved, swap the `Eula` / `Billing` / `ApiKey` env block for the
`DownloadLicense` + `Mounts:License` flow described in
[Run the container disconnected from the internet](https://learn.microsoft.com/azure/ai-services/language-service/personally-identifiable-information/how-to/use-containers#run-the-container-disconnected-from-the-internet).

## References

- [Use Azure AI Language PII containers](https://learn.microsoft.com/azure/ai-services/language-service/personally-identifiable-information/how-to/use-containers)
- [Presidio — Adding recognizers](https://microsoft.github.io/presidio/analyzer/adding_recognizers)
- [Presidio sample — Integrating with external services](https://microsoft.github.io/presidio/samples/python/integrating_with_external_services)
