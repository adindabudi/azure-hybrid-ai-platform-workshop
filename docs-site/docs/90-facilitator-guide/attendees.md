---
title: Provision attendees
sidebar_position: 3
---

# Provision attendees

Run after `terraform apply` succeeds and the smoke-test is green. This
creates one namespace per attendee with the workload identity,
ResourceQuota, Key Vault CSI binding, and APIM subscription key wired up.

## Step 1 — Run the bootstrap script

```bash
./scripts/bootstrap-attendees.sh
```

Loops over the `attendee_count` you configured in
[`infra/env/workshop.tfvars`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/blob/main/infra/env/workshop.tfvars)
and, for each attendee `NN`:

- Creates namespace `attendee-NN`.
- Applies a 4 vCPU / 8 GiB ResourceQuota + per-container LimitRange.
- Creates the `agent-sa` ServiceAccount annotated for workload identity.
- Creates the `azure-kv-shared` SecretProviderClass (KV CSI).
- Creates the `apim-credentials` k8s Secret containing that attendee's
  APIM subscription key.

Re-runnable. Idempotent.

### Verify

```bash
kubectl get ns | grep attendee-
kubectl get serviceaccount,secretproviderclass,secret -n attendee-01
```

You should see `agent-sa`, `azure-kv-shared`, `apim-credentials` in
every attendee namespace.

## Step 2 — Print one handout per attendee

For each attendee `NN` (e.g. `01`, `02`, …):

```bash
./scripts/print-attendee-handout.sh 03
```

Prints the per-attendee connection slip — `APIM_GATEWAY`,
`APIM_GATEWAY_URL`, `APIM_KEY`, namespace, deployment names, Cosmos /
KV / Search endpoints, App Insights connection string, plus the curl
smoke-test the attendee will run in M0.

The handout already includes `export APIM_GATEWAY_URL=…` and
`export APIM_KEY=…` lines that the attendee copy-pastes into their
shell — they never have to touch Terraform.

## Step 3 — Distribute the handouts

Pick **one** distribution channel — never mix to avoid leakage.

### Option A — Per-attendee email via Microsoft Graph (recommended)

Best for in-tenant workshops where you already have everyone's email
plus a Temporary Access Pass (TAP) from your Entra admin. The script
uses your own `az login` session to call `/me/sendMail`, so no service
principal or app registration is needed.

Build a CSV (`attendees.csv`) **outside the repo** — it contains email
addresses and TAPs:

```csv
number,email,name,tap
01,alice@contoso.com,Alice Tan,12345-ABCDE-FGHIJ
02,bob@contoso.com,Bob Wijaya,67890-KLMNO-PQRST
```

Dry-run first to inspect what will be sent:

```bash
./scripts/send-attendee-emails.sh ~/attendees.csv
```

Then actually send:

```bash
./scripts/send-attendee-emails.sh ~/attendees.csv --send
```

Each email contains: TAP block (skipped if the `tap` column is empty),
full connection slip including APIM key, and a link to the docs site.
The subject is `[AI Gateway Workshop] Your handout — attendee-NN`. A
copy lands in your Sent Items.

If your tenant blocks `Mail.Send` delegated, ask your admin to grant
it for your account, or fall back to Option B/C.

### Option B — Printed paper, hand to each attendee in person

The most secure, zero-digital-trail option. Concatenate all handouts
into a single PDF for printing:

```bash
OUT="$HOME/handouts-$(date +%Y%m%d).txt"
: > "$OUT" && chmod 600 "$OUT"
for n in $(seq -f '%02g' 1 10); do
  ./scripts/print-attendee-handout.sh "$n" >> "$OUT"
  printf '\n\n\f\n' >> "$OUT"  # form-feed = page break
done
# Print, then immediately:
shred -u "$OUT"
```

Print 1-per-page, hand to each attendee at check-in, ask them to
shred after the workshop.

### Option C — Split-channel (encrypted ZIP + out-of-band password)

When you don't have TAPs and email is your only channel:

1. ZIP each attendee's handout with a per-person password:
   ```bash
   for n in $(seq -f '%02g' 1 10); do
     ./scripts/print-attendee-handout.sh "$n" > "/tmp/${n}.txt"
     PASS=$(openssl rand -base64 9)
     7z a -p"$PASS" -mhe=on "/tmp/handout-${n}.7z" "/tmp/${n}.txt"
     echo "attendee-${n}: $PASS"
     rm "/tmp/${n}.txt"
   done
   ```
2. Email each ZIP to the corresponding attendee.
3. Send the password via a **different** channel (SMS, WhatsApp,
   in-person).

### What NOT to do

- ❌ Single email with all 10 handouts (one leak = ten compromises).
- ❌ Posting in Teams/Slack channel even if "private" (chat retention).
- ❌ Pinning a Confluence/Notion page with keys (search indexes).
- ❌ Letting attendees screenshot the projector (don't display on
  shared screen).

## Step 4 — Reset (during the workshop, if needed)

If an attendee gets their namespace into a bad state, blow away the
workloads (keeps SA / quota / SPC):

```bash
./scripts/reset-attendee.sh 03
```

If you also need to re-seed the SA / SPC / Secret, re-run
`bootstrap-attendees.sh` — it's idempotent.

## What attendees can and cannot do

| Attendee can | Attendee cannot |
| --- | --- |
| `az login` and read their tenant | `az role assignment create` on RG |
| `kubectl … -n attendee-NN` | `kubectl get nodes` / cross-namespace |
| Send requests through APIM with their subscription key | Edit APIM policies, create backends, list other subscription keys |
| Read their request in Application Insights | Read other attendees' traces |
| Register OAuth apps in their tenant (default user role) | Grant tenant-admin consent |

This is the boundary the workshop assumes. Apply policies and onboard
backends yourself — see [Apply the AI-gateway policies](./apply-policies.md).

## Next

[Apply the AI-gateway policies](./apply-policies.md)
