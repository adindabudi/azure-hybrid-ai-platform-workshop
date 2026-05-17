---
sidebar_position: 1
title: Industry playbooks — Indonesia
---

# Industry playbooks — Indonesia

The same workshop pattern (APIM AI Gateway + Azure OpenAI + Agent Framework
+ MCP + evals/red-team) maps onto the specific regulatory and commercial
constraints of each regulated industry. This appendix translates the
patterns you built in M1–M5 into the language your customer's
compliance, risk, and business owners use.

Each section follows the same three-part structure:

1. **Business reality** — the regulator, the clause, the auditor question.
2. **Capability mapping** — which workshop pattern answers that question.
3. **Real-world scenario** — a concrete deployment story you can quote.

---

## BFSI — banks, insurers, multifinance

### Business reality

Indonesian financial services run under **OJK** supervision plus a
growing AI-specific overlay:

- **POJK 11/POJK.03/2022** — IT risk management for commercial banks;
  Article 33 requires documented model validation and ongoing
  performance monitoring for any model used in credit, fraud, or
  customer-facing decisions.
- **SEOJK 21/SEOJK.03/2017** — risk-based bank IT supervision; defines
  the audit-trail retention and segregation-of-duties expectations that
  AI assistants must respect when they touch core banking data.
- **UU PDP 27/2022** — Indonesia's personal data protection law;
  customer **NIK**, account numbers, and **MSISDN** are personal data
  with a lawful-basis and minimisation obligation that applies to every
  prompt and every log line.
- **BCBS 239** — for systemically important banks, the principle that
  risk data must be aggregated *accurately, completely, and on time* —
  it extends to AI-derived risk signals.

The auditor question that decides whether the project ships:
*"For every model decision in the last 24 months, can you produce
the exact prompt, the model version, the retrieved documents, who
called the API, and what came back — within four working hours?"*

### Capability mapping

| Business requirement | Workshop pattern | Where |
| --- | --- | --- |
| NIK / account number must not leave Indonesia | APIM policy routes any request with `x-data-classification: restricted` to the IDC backend pool | M1 [enterprise patterns](../01-gateway-foundations/enterprise-patterns.md) |
| PII redacted before it reaches model logs | `pii-mask-outbound.xml` policy + the [Presidio container](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/tree/main/apps/presidio-pii) on the IDC AKS | M1 + M2 |
| Every prompt + completion archived for 7 years | `audit-trail-eventhub.xml` policy → Event Hub → ADLS Gen2 immutable storage | M2 [intro](../02-finops-observability-security/intro.md) |
| Model validation evidence retained per release | Foundry evaluators + PyRIT regression gate; `eval-results.json` checked into release branch | M5 [`apps/eval-suite/`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/tree/main/apps/eval-suite) |
| Per-LOB cost transparency | `emit-token-metric` with subscription dimensions + KQL chargeback report | M2 [intro](../02-finops-observability-security/intro.md) |
| Jailbreak / prompt-injection blocked at edge | `llm-content-safety` with Prompt Shields; Defender for Cloud AI threat alerts into SOC | M2 Step 4 |

### Real-world scenario

A retail bank deploys a **complaint-triage agent** for its contact
centre. The agent reads the latest CRM ticket, classifies into one of
six product complaints, drafts a Bahasa Indonesia reply, and proposes a
**SLA** based on the customer segment.

- The CRM lookup happens via the **MCP server in M3**, sitting in IDC.
- The agent uses **gpt-5-mini in IDC** for any request whose ticket
  contains a NIK; SEA region is the fallback for English-only flows
  without PII (e.g., expat customers).
- Every call carries an **Entra ID JWT** from the contact-centre app
  registration; the M2 policy enforces it.
- The **monthly OJK report** is one KQL query against the Event Hub
  archive: total decisions, model version, p95 latency, denied prompts
  (Prompt Shields blocks), and the per-team chargeback line item.
- Before each release, the same eval suite from M5 runs in GitHub
  Actions; a regression on `TaskAdherence` or any new PyRIT bypass
  blocks the merge.

The pitch in one sentence: *"Your existing OJK-audit muscle keeps
working; AI just becomes another regulated workload behind the same
gateway, with the same logging discipline and the same auditor
interface."*

---

## Healthcare — hospitals, payers (BPJS), pharma

### Business reality

- **Permenkes 24/2022** — Indonesia's electronic medical record (RME)
  regulation; mandates that patient data resides on infrastructure
  located in Indonesia.
- **UU PDP 27/2022** — patient data is sensitive personal data with a
  stricter consent and breach-notification regime than ordinary PII.
- **HL7 FHIR R4** is the de-facto interchange format the Ministry of
  Health is pushing for interoperability between hospital information
  systems and the **SatuSehat** national platform.
- For hospitals that take international patients (Bali, Jakarta
  private), additional contractual obligations from insurers
  (HIPAA-style in spirit if the patient is American, GDPR if European).

The clinician question: *"If an AI summarises this patient's chart and
the summary is wrong, who is responsible — the doctor, the hospital, or
the vendor?"* The technical answer needs **traceability** (every claim
in the AI summary linked back to the source FHIR resource) and
**explainability** (the doctor must be able to audit the prompt).

### Capability mapping

| Business requirement | Workshop pattern | Where |
| --- | --- | --- |
| Patient identifiers stay on Indonesian soil | IDC-only backend; APIM denies any route that resolves to a non-IDC region for `x-data-classification: medical` | M1 enterprise patterns |
| De-identify before sending to an external summary model | Presidio container with **custom recognisers** for NIK, BPJS member number, Indonesian phone numbers | M2, [`apps/presidio-pii/`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/tree/main/apps/presidio-pii) |
| Every AI claim traceable to source FHIR resource | MCP server returns resource URIs the agent must cite; the eval suite scores `Groundedness` per response | M3 + M5 |
| Clinician audit trail | Audit-trail policy + prompt-hash dashboard tile in App Insights | M2 |
| Multilingual safety (Bahasa Indonesia + English + Tagalog for international patients) | Prompt Shields is language-agnostic by design; the attack catalog in M2 has Bahasa Indonesia samples | M2 Step 4 |

### Real-world scenario

A tertiary hospital builds an **MCP-fronted clinical summariser**: the
agent reads the patient's FHIR bundle, drafts a one-page handover note
for the on-call doctor, and highlights any new lab result outside the
reference range.

- The FHIR fetch is an MCP tool sitting in the hospital's IDC, talking
  to the existing hospital information system over HL7 FHIR R4.
- Presidio masks **all identifiers** (NIK, BPJS, MRN) before any text
  leaves the IDC; the model never sees identity, only de-identified
  clinical narrative.
- The system prompt mandates citation: *"Every clinical claim must
  cite the FHIR resource ID."* `Groundedness` evaluator scores < 0.8
  fail the release.
- Defender for Cloud AI threat alerts are routed to the hospital's
  cyber SOC; the **medical safety officer** sees the same dashboard.

The pitch: *"Indonesian compliance, international clinical standards,
zero patient data leaves the country, and the doctor's note has a
citation footnote on every sentence."*

---

## Telco — operators, MVNO, infrastructure

### Business reality

- **Permenkominfo 5/2021** and updates — content moderation and lawful
  intercept obligations.
- **UU PDP 27/2022** — MSISDN, IMEI, location, and call-detail-records
  are personal data; mass-scale processing requires strong purpose
  limitation.
- **Bank Indonesia** — for telcos with payments licences (e-money,
  remittance), BI's **ZSK** (Zona Server Khusus) and payment-systems
  rules add a residency layer on top of OJK supervision.
- **Scale**: tens of millions of subscribers, hundreds of thousands of
  customer-care interactions a day, single-digit-rupiah unit
  economics — *"can we afford to let AI answer this?"* is a literal
  per-token question.

### Capability mapping

| Business requirement | Workshop pattern | Where |
| --- | --- | --- |
| Sub-cent unit economics per interaction | Semantic cache (20–40% hit on FAQ workload); load-balance to cheap model (`phi-4-mini-instruct`) for low-complexity intents | M1.3 + M1.4 |
| Per-product-line chargeback | Subscription-key-per-team in APIM; KQL chargeback tile per team in Tile 1 | M2 |
| MSISDN must not appear in third-party model logs | Same residency policy as BFSI: `x-data-classification: restricted` → IDC | M1 |
| Burst capacity for promo events (cuti bersama, harbolnas) | APIM + AOAI PTU for sustained baseline + PAYG fallback for burst | M2 Step 4.5 |
| Per-tenant abuse blocking (MVNO partners) | `quota-by-key-monthly` + `ip-filter-allowlist` | M1.4 |
| 24x7 SOC integration | Defender for Cloud AI threat protection → Sentinel | M2 Step 4 |

### Real-world scenario

A national operator deploys a **MyOperator chatbot** for self-service:
balance check, package switching, plan recommendation, troubleshooting.

- 70% of intents hit the **semantic cache** (the bottom 100 FAQ
  templates account for that share); those return in 50 ms and don't
  hit Azure OpenAI at all.
- Complex intents fall through to `phi-4-mini-instruct` on AKS for
  ~80% of the long-tail; only the top 10% of nuanced intents reach
  `gpt-5-mini`.
- Account-modifying intents go through the **MCP server** with OAuth
  PKCE — the agent can read the customer's plan but only proposes the
  change; a deterministic backend confirms.
- The CFO sees a chargeback dashboard split by **B2C, B2B, and the
  MVNO partner brand**; the marketing team's promo spike for harbolnas
  shows up as a chargeback line item the same day, not three weeks
  later in a manual report.

The pitch: *"AI that costs single-digit rupiah per interaction, scales
to a national subscriber base, and gives every business line a
chargeback they can defend to finance."*

---

## How to use this appendix in a workshop

- During the in-room workshop, ask each table which industry they
  represent and let them open the matching section while you walk
  through M0.0.
- The capability-mapping tables are the script for the *"so what does
  this mean for my project on Monday?"* conversation in the wrap-up.
- The real-world scenarios are deliberately concrete and quotable in a
  customer-facing solution-architecture document.

Need a scenario for an industry not listed here (government, retail,
manufacturing)? Open an issue on the
[workshop repository](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/issues)
and we'll fold it into the next revision.
