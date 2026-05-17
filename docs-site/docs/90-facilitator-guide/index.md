---
title: Facilitator Guide
sidebar_position: 1
---

# Facilitator Guide

This section is for **workshop admins** running the landing zone, not
for attendees. The materials assume you have:

- Owner (or Contributor + RBAC Administrator) on the workshop resource
  group.
- Local Terraform 1.9+, Azure CLI 2.61+, `kubectl`, `jq`.
- Permission to register Microsoft Entra apps in the workshop tenant.

If you are an attendee, ignore this section and start at
[M0 — Setup](../00-intro/setup.md).

## End-to-end flow

```mermaid
flowchart TB
    subgraph T1["T-1 day"]
        direction TB
        S1["1. Provision the landing zone<br/>(~30 min, terraform apply)<br/>→ ./facilitator-guide/provision"]
        S2["2. Bootstrap per-attendee namespaces,<br/>RBAC, secrets<br/>→ ./facilitator-guide/attendees"]
        S3["3. Apply the APIM AI-gateway policies<br/>→ ./facilitator-guide/apply-policies<br/><i>(single command: ./scripts/apply-apim-policies.sh)</i>"]
        S1 --> S2 --> S3
    end
    subgraph WM["Workshop morning"]
        direction TB
        S4["4. Run smoke-test, then print and<br/>hand out the per-attendee slip<br/>→ ./facilitator-guide/attendees"]
    end
    T1 ==> WM
```

Each attendee then follows [M0 — Setup](../00-intro/setup.md) using the slip
of paper you handed them.

## What goes where

| Concern | Page |
| --- | --- |
| `terraform apply`, regions, what gets deployed | [Provision the landing zone](./provision.md) |
| Per-attendee namespaces, secrets, handout printing | [Provision attendees](./attendees.md) |
| APIM API import, backends, MI role assignments, policy XML | [Apply the AI-gateway policies](./apply-policies.md) |

## Reuse for self-paced learners

If you are running M0–M6 alone on your own subscription, follow the
facilitator guide in order, then run the attendee labs against your own
gateway. The env vars you would normally hand out (`APIM_GATEWAY_URL`,
`APIM_KEY`, etc.) come from `terraform output` plus
`./scripts/print-attendee-handout.sh 01` after the bootstrap completes.
