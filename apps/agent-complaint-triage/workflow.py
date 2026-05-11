"""Three-step Agent Framework workflow with checkpointing.

Demonstrates the M4 deep-dive scenario: multi-agent orchestration where
each step is a ChatAgent and the workflow state is checkpointed to disk
so a crash mid-flight can be resumed.

Step 1 (Triage)     — classify the complaint and pick the specialist
Step 2 (Specialist) — draft a customer-facing response
Step 3 (Compliance) — redact PII, enforce tone, sign off

Two flavors are shown:

* ``run_sequential`` — the cleanest path using ``SequentialBuilder`` from
  the orchestrations subpackage. Use this when you don't need
  conditional edges or fan-out/fan-in.
* ``run_with_checkpoints`` — uses the lower-level ``WorkflowBuilder``
  + ``FileCheckpointStorage`` for crash recovery and "resume from
  last good step" demos.

API references:
* https://learn.microsoft.com/agent-framework/workflows/sequential
* https://learn.microsoft.com/agent-framework/workflows/checkpointing
"""

from __future__ import annotations

import asyncio
import os
from pathlib import Path

from agent_framework import FileCheckpointStorage, WorkflowBuilder
from agent_framework.openai import OpenAIChatClient
from agent_framework.orchestrations import SequentialBuilder


def _client() -> OpenAIChatClient:
    return OpenAIChatClient(
        model=os.environ["MODEL_NAME"],
        azure_endpoint=os.environ["APIM_URL"],
        api_version="2024-10-21",
        api_key=os.environ["APIM_KEY"],
        default_headers={"x-model-tier": os.environ.get("MODEL_TIER", "premium")},
    )


def build_agents():
    client = _client()
    triage = client.create_agent(
        name="Triage",
        instructions=(
            "Classify the complaint as transactional, account-access, "
            "informational, or general. Output one line: '<category>: <one-sentence summary>'."
        ),
    )
    specialist = client.create_agent(
        name="Specialist",
        instructions=(
            "You receive a triaged complaint. Draft a polite customer-facing "
            "reply (max 4 sentences) and propose two concrete next steps."
        ),
    )
    compliance = client.create_agent(
        name="Compliance",
        instructions=(
            "Redact any names, account numbers, or phone numbers. "
            "Ensure tone is professional. Append the sign-off "
            "'— Customer Care Team'. Return only the cleaned reply."
        ),
    )
    return triage, specialist, compliance


async def run_sequential() -> None:
    """Cleanest path — three agents wired in a straight pipeline."""
    triage, specialist, compliance = build_agents()
    workflow = SequentialBuilder(
        participants=[triage, specialist, compliance]
    ).build()

    events = await workflow.run(
        "Saldo saya hilang Rp 5 juta tanpa transaksi yang saya kenali. Tolong bantu segera."
    )
    # `events.get_outputs()` returns the final outputs from the workflow.
    for output in events.get_outputs():
        print(output)


async def run_with_checkpoints() -> None:
    """Lower-level WorkflowBuilder with disk-backed checkpoints.

    Run once; kill the process during step 2; rerun with the same
    checkpoint dir to see the workflow resume from the last good step.
    """
    triage, specialist, compliance = build_agents()
    storage = FileCheckpointStorage(Path("./.checkpoints").resolve())

    workflow = (
        WorkflowBuilder(start_executor=triage)
        .add_edge(triage, specialist)
        .add_edge(specialist, compliance)
        # ``with_checkpointing`` is the documented method (NOT
        # ``with_checkpoint_storage``). Pair it with FileCheckpointStorage
        # to get crash-resume semantics.
        .with_checkpointing(storage)
        .build()
    )

    events = await workflow.run(
        "Aplikasi mobile banking saya keluar terus saat login. Sudah uninstall reinstall."
    )
    for output in events.get_outputs():
        print(output)


if __name__ == "__main__":
    # Switch which one to run via env var so the docs can demo both.
    if os.environ.get("WORKFLOW_MODE") == "checkpoint":
        asyncio.run(run_with_checkpoints())
    else:
        asyncio.run(run_sequential())
