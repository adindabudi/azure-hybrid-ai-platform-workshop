"""Sample MCP server used in M3 — Secure tool access through APIM.

Exposes a single ``lookup_customer`` tool over the MCP SSE transport on
port 8765. The tool reads a synthetic dataset bundled with the image
(see ``customers.json``) — no real PII, no external dependencies.

The server itself is single-tenant and **unauthenticated** on purpose:
APIM bolts OAuth/PKCE and rate-limit-by-key on at the gateway layer
(see ``policies/mcp-oauth-pkce.xml``). This separation is the central
design point of M3.
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s :: %(message)s",
)
log = logging.getLogger("mcp-customer-tool")

DATA_PATH = Path(__file__).with_name("customers.json")
with DATA_PATH.open("r", encoding="utf-8") as fh:
    CUSTOMERS: list[dict[str, Any]] = json.load(fh)

INDEX_BY_ID: dict[str, dict[str, Any]] = {c["customer_id"]: c for c in CUSTOMERS}
INDEX_BY_PHONE: dict[str, dict[str, Any]] = {c["phone"]: c for c in CUSTOMERS}

mcp = FastMCP(
    name="customer-tool",
    instructions=(
        "Internal customer lookup tool for the Hybrid AI Platform Workshop. "
        "All data is synthetic. Never echo full PAN or CVV — fields ending "
        "in `_masked` are already redacted server-side."
    ),
)


@mcp.tool()
def lookup_customer(customer_id: str | None = None,
                    phone: str | None = None) -> dict[str, Any]:
    """Look up a customer by either ``customer_id`` or ``phone``.

    Exactly one identifier must be provided. Returns the customer record
    with sensitive fields server-side masked, or an ``error`` field when
    the customer cannot be found.
    """
    if bool(customer_id) == bool(phone):
        return {"error": "Provide exactly one of customer_id or phone."}

    record = INDEX_BY_ID.get(customer_id) if customer_id else INDEX_BY_PHONE.get(phone)
    if record is None:
        return {"error": "customer_not_found"}

    log.info("lookup_customer hit id=%s phone=%s", customer_id, phone)
    return record


@mcp.tool()
def list_recent_complaints(customer_id: str, limit: int = 5) -> dict[str, Any]:
    """Return the most recent complaint history for a customer."""
    record = INDEX_BY_ID.get(customer_id)
    if record is None:
        return {"error": "customer_not_found"}
    history = record.get("recent_complaints", [])[: max(1, min(limit, 20))]
    return {"customer_id": customer_id, "complaints": history}


if __name__ == "__main__":
    # FastMCP exposes both stdio and SSE transports. For the in-cluster
    # deployment we run SSE on 0.0.0.0:8765 — APIM is the only thing
    # allowed to reach it (NetworkPolicy in deployment.yaml).
    host = os.environ.get("MCP_HOST", "0.0.0.0")
    port = int(os.environ.get("MCP_PORT", "8765"))
    log.info("starting MCP SSE server on %s:%d", host, port)
    mcp.settings.host = host
    mcp.settings.port = port
    mcp.run(transport="sse")
