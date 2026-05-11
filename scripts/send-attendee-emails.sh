#!/usr/bin/env bash
# send-attendee-emails.sh
#
# Send per-attendee workshop handout + Temporary Access Pass via Microsoft
# Graph /me/sendMail. Uses your own az CLI session for delegated auth — no
# service principal or app reg needed.
#
# FACILITATOR-ONLY. Requires:
#   - Microsoft Graph Mail.Send delegated permission (default on most
#     M365 corp tenants; if blocked, ask your tenant admin to grant).
#   - jq, curl, terraform, az logged in (`az login`).
#   - Terraform state present (the handout script reads outputs from it).
#
# Usage:
#   ./scripts/send-attendee-emails.sh attendees.csv          # dry-run
#   ./scripts/send-attendee-emails.sh attendees.csv --send   # actually send
#
# attendees.csv format (header required):
#   number,email,name,tap
#   01,alice@contoso.com,Alice Tan,12345-ABCDE-FGHIJ
#   02,bob@contoso.com,Bob Wijaya,67890-KLMNO-PQRST
#   ...
#
# The TAP column can be left empty (",,") if you've already shared TAPs
# through another channel — that section will be omitted from the email.

set -euo pipefail

CSV="${1:-}"
DRY_RUN=1
[[ "${2:-}" == "--send" ]] && DRY_RUN=0

if [[ -z "$CSV" ]]; then
  cat <<USAGE >&2
Usage: $0 <attendees.csv> [--send]

CSV format (header required):
  number,email,name,tap
  01,alice@contoso.com,Alice Tan,12345-ABCDE
  02,bob@contoso.com,Bob Wijaya,67890-FGHIJ

Without --send, this is a dry-run that prints what would be sent.
USAGE
  exit 1
fi

[[ -f "$CSV" ]] || { echo "CSV not found: $CSV" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not installed" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

# Acquire Graph token (your own delegated session).
TOKEN=$(az account get-access-token --resource https://graph.microsoft.com \
  --query accessToken -o tsv 2>/dev/null) \
  || { echo "az account get-access-token failed. Run 'az login' first." >&2; exit 2; }

# Validate /me works (i.e., the token is delegated, not app-only).
ME=$(curl -sS -H "Authorization: Bearer $TOKEN" \
  https://graph.microsoft.com/v1.0/me 2>/dev/null \
  | jq -r '.userPrincipalName // empty')
[[ -z "$ME" ]] && { echo "Could not resolve /me — is your az session delegated?" >&2; exit 2; }

echo "==> Sender:  $ME"
echo "==> Mode:    $([[ $DRY_RUN -eq 1 ]] && echo 'DRY-RUN (will not send)' || echo 'LIVE (will send)')"
echo ""

DOCS_URL="${WORKSHOP_DOCS_URL:-https://adindabudi.github.io/azure-hybrid-ai-platform-workshop/}"

# Skip CSV header; loop rows.
SENT=0
FAILED=0
tail -n +2 "$CSV" | while IFS=, read -r NUM EMAIL NAME TAP; do
  # Trim whitespace
  NUM="${NUM//[[:space:]]/}"
  EMAIL="${EMAIL//[[:space:]]/}"
  NAME="$(echo "$NAME" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  TAP="${TAP//[[:space:]]/}"

  [[ -z "$NUM" || -z "$EMAIL" ]] && continue

  # 10# forces base-10 (08, 09 are not octal).
  NUM=$(printf '%02d' "$((10#$NUM))")
  NS="attendee-${NUM}"

  echo "==> ${NS} → ${NAME:-<no-name>} <${EMAIL}>"

  # Generate handout body (re-uses the existing script).
  HANDOUT=$(./scripts/print-attendee-handout.sh "$NUM" 2>&1)

  # Optional TAP block.
  TAP_BLOCK=""
  if [[ -n "$TAP" ]]; then
    TAP_BLOCK=$(cat <<TAP_EOF

== Step 1 — Entra ID sign-in (before the workshop) ==

You have a Temporary Access Pass (TAP) for the workshop tenant. Use it
once to set up your workshop account. TAPs are single-use and expire
within 24 hours.

  TAP:         ${TAP}
  Sign-in URL: https://login.microsoftonline.com/

TAP_EOF
)
  fi

  BODY=$(cat <<EMAIL_EOF
Hi ${NAME:-there},

Welcome to the Hybrid AI Platform Workshop. Below are your connection
details. Treat the subscription key like a password — do not share, do
not commit to git, do not paste into chat threads.
${TAP_BLOCK}
== Step 2 — Connection details ==

${HANDOUT}

== Workshop materials ==

  ${DOCS_URL}

Start at M0 (Setup). Every command in M0–M6 is in the docs; the slip
above feeds the two env vars you need to export.

If anything is wrong, reply to this email before the workshop starts
so we can re-issue your credentials.

— Workshop Team
EMAIL_EOF
)

  # Build JSON payload safely.
  PAYLOAD=$(jq -n \
    --arg subject "[AI Gateway Workshop] Your handout — ${NS}" \
    --arg body "$BODY" \
    --arg to "$EMAIL" \
    '{
      message: {
        subject: $subject,
        body: {contentType: "Text", content: $body},
        toRecipients: [{emailAddress: {address: $to}}]
      },
      saveToSentItems: true
    }')

  if (( DRY_RUN == 1 )); then
    echo "    (dry-run; body=${#BODY} bytes, tap=$([[ -n "$TAP" ]] && echo 'yes' || echo 'no'))"
  else
    HTTP=$(curl -sS -o /tmp/sendmail-resp.json -w "%{http_code}" \
      -X POST "https://graph.microsoft.com/v1.0/me/sendMail" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      --data "$PAYLOAD")
    if [[ "$HTTP" == "202" ]]; then
      echo "    sent ✓"
    else
      echo "    ✗ HTTP $HTTP"
      cat /tmp/sendmail-resp.json
      echo ""
    fi
  fi
done

echo ""
if (( DRY_RUN == 1 )); then
  echo "Dry-run complete. To actually send:"
  echo "  $0 $CSV --send"
else
  echo "Done."
fi
