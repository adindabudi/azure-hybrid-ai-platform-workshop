# presidio-pii — single-shot PII redactor for the AI gateway

> Custom Presidio orchestrator container that exposes one REST endpoint
> (`POST /redact`) so the APIM `pii-mask-outbound.xml` policy only needs
> a single `<send-request>`. Combines spaCy NER + Indonesian regex
> recognizers + (optional) Azure AI Language PII as a Presidio
> `RemoteRecognizer`.

## Why this exists

The first PII-mask draft used a chain of `<find-and-replace>` policies
inside `<outbound>`, but the APIM `find-and-replace` documentation is
explicit that it does **substring replacement, not regex** (per
[MS Learn](https://learn.microsoft.com/azure/api-management/find-and-replace-policy)).
That means the regex-looking patterns were silently never matching. Worst
kind of safety bug — looks correct, doesn't work.

This service replaces that broken approach with the Microsoft-recommended
pattern:

1. APIM does **one** `<send-request>` to `/redact` with the model's
   completion text.
2. We run Presidio analyzer (built-in recognizers + Indonesian regex
   recognizers + optionally an Azure AI Language `RemoteRecognizer`)
   followed by the anonymizer in one Python call.
3. We return the redacted text. APIM swaps it into the outbound body
   via `<set-body>`.

## What's in the box

| Component | Source | Coverage |
|---|---|---|
| `AnalyzerEngine` (spaCy `en_core_web_lg`) | Presidio default | `PERSON`, `LOCATION`, `ORGANIZATION`, `EMAIL_ADDRESS`, `PHONE_NUMBER`, `URL`, `IP_ADDRESS`, `CREDIT_CARD`, `IBAN_CODE`, `US_SSN`, `DATE_TIME`, `CRYPTO`, … |
| `recognizers/indonesian.py` | this repo | `ID_NIK` (16-digit), `ID_NPWP` (legacy 15-digit formatted), `ID_PHONE` (`+62` / `0` mobile + fixed-line), `ID_BANK_ACCOUNT` (low-confidence 10–16 digit) |
| `recognizers/text_analytics.py` (optional) | port of [Presidio sample](https://microsoft.github.io/presidio/samples/python/integrating_with_external_services) | Azure AI Language PII categories — turned on by `LANGUAGE_ENDPOINT` + `LANGUAGE_KEY` env vars |
| `AnonymizerEngine` | Presidio default | `replace` operators per entity, `[NIK-MASKED]` / `[PERSON-MASKED]` / etc. |

## Two deployment modes

### Mode A — Presidio only (workshop default)

No external entitlement needed. spaCy NER catches names / locations /
orgs in English-language outputs; Indonesian regex recognizers catch
NIK / NPWP / phone / bank account.

```bash
kubectl apply -f deployment.yaml
```

### Mode B — Presidio + Azure AI Language

Adds high-recall PII detection from Azure AI Language. Use this when
your AKS cluster also runs the Language PII container (see
[apps/language-pii-cpu/](../language-pii-cpu/)) or when you can reach a
cloud Language Service endpoint from the cluster.

```bash
# 1) (Optional) deploy the Language PII container alongside this one
kubectl apply -f ../language-pii-cpu/language-pii-cpu.yaml

# 2) wire credentials into this Deployment as a Secret
kubectl create secret generic language-pii \
  -n presidio \
  --from-literal=endpoint='http://language-pii.language-pii.svc.cluster.local:5000' \
  --from-literal=key='<api-key-or-any-string-for-container-mode>'

# 3) re-apply the Deployment (it consumes the Secret if present)
kubectl apply -f deployment.yaml
```

The Deployment YAML wires `LANGUAGE_ENDPOINT` / `LANGUAGE_KEY` from the
optional Secret; if the Secret is missing the env vars are unset and the
Language recognizer simply doesn't register (logged at startup).

## REST contract

### `POST /redact`

```bash
curl -sS -X POST http://localhost:8080/redact \
  -H 'Content-Type: application/json' \
  -d '{"text":"Hubungi Pak Budi (NIK 3171012345678901, HP 081234567890) ke rekening 1234567890123."}'
```

```json
{
  "text": "Hubungi Pak [PERSON-MASKED] (NIK [NIK-MASKED], HP [PHONE-MASKED]) ke rekening [ACCT-MASKED].",
  "entities": [
    {"type": "PERSON",          "start": 11, "end": 15, "score": 0.85},
    {"type": "ID_NIK",          "start": 21, "end": 37, "score": 0.7 },
    {"type": "ID_PHONE",        "start": 42, "end": 54, "score": 0.7 },
    {"type": "ID_BANK_ACCOUNT", "start": 67, "end": 80, "score": 0.4 }
  ]
}
```

### `GET /supportedentities`

Returns the union of entity types the analyzer can emit. Useful for
verifying that Indonesian / Language recognizers are wired up.

### `GET /healthz`

Returns `{"status":"ok"}` once gunicorn is serving. Used by the
Deployment's readiness/liveness probes.

## Local dev (no AKS)

```bash
cd apps/presidio-pii
docker build -t presidio-pii:dev .
docker run --rm -p 8080:8080 presidio-pii:dev
# Mode B: also pass -e LANGUAGE_ENDPOINT=... -e LANGUAGE_KEY=...
```

## Build for the workshop ACR

```bash
ACR=$(terraform -chdir=../../infra output -raw acr_login_server)
az acr build -r "${ACR%%.*}" -t presidio-pii:latest .
```

After the build finishes, [`apps/presidio-pii/deployment.yaml`](deployment.yaml)
references `${ACR_LOGIN_SERVER}/presidio-pii:latest`; the AKS kubelet
identity already has `AcrPull`, so no `imagePullSecret` is needed.

## How APIM uses this service

[`policies/pii-mask-outbound.xml`](../../policies/pii-mask-outbound.xml) is
attached to the API by `scripts/apply-apim-policies.sh --with-pii-mask`.
It does:

1. Extract the model's completion text from the outbound body.
2. `<send-request>` to `http://presidio-pii.presidio.svc.cluster.local/redact`.
3. Replace the completion text with the redacted version returned by
   `/redact`, leaving everything else (token usage, role markers, model
   id) untouched.

The policy is a fail-open on `/redact` errors: if the service is
unreachable the original (un-redacted) response goes through, and the
audit log records `pii-redactor-unavailable`. If you operate in a
fail-closed posture, flip `ignore-error="true"` to `false` in the
policy XML and APIM will return `502` when Presidio is down.

## References

- Presidio docs — [Adding recognizers](https://microsoft.github.io/presidio/analyzer/adding_recognizers)
- Presidio docs — [Integrating with external services](https://microsoft.github.io/presidio/samples/python/integrating_with_external_services)
- Presidio docs — [Getting started](https://microsoft.github.io/presidio/getting_started/getting_started_text)
- Azure AI Language — [PII detection containers](https://learn.microsoft.com/azure/ai-services/language-service/personally-identifiable-information/how-to/use-containers)
- APIM — [find-and-replace policy](https://learn.microsoft.com/azure/api-management/find-and-replace-policy) (the broken approach this service replaces)
