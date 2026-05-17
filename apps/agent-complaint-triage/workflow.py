"""Three-step Agent Framework workflow with checkpointing.

Demonstrates the M4 deep-dive scenario: multi-agent orchestration where
each step is an ``Agent`` and the workflow state is checkpointed to
disk so a crash mid-flight can be resumed.

Step 1 (Triage)     — classify the complaint and pick the specialist
Step 2 (Specialist) — draft a customer-facing response
Step 3 (Compliance) — redact PII, enforce tone, sign off

Two flavors are shown:

* ``run_sequential`` — the cleanest path using ``SequentialBuilder`` from
  the orchestrations subpackage. Use this when you don't need
  conditional edges or fan-out/fan-in.
* ``run_with_checkpoints`` — uses the lower-level ``WorkflowBuilder``
  plus ``FileCheckpointStorage`` for crash recovery and
  "resume from last good step" demos.

agent-framework 1.4.0 API notes
-------------------------------
* Use ``OpenAIChatCompletionClient`` (chat completions) for APIM —
  ``OpenAIChatClient`` hits ``/v1/responses`` which APIM Developer does
  not import. See ``agent.py`` for the full reasoning.
* ``client.create_agent(...)`` was removed. Build ``Agent(client=...)``
  directly.
* ``WorkflowBuilder.with_checkpointing(storage)`` was removed.
  ``checkpoint_storage`` is now a constructor kwarg.

API references:
* https://learn.microsoft.com/agent-framework/workflows/sequential
* https://learn.microsoft.com/agent-framework/workflows/checkpointing
"""

from __future__ import annotations

import asyncio
import os
import warnings
from pathlib import Path

warnings.filterwarnings("ignore", message=".*is experimental.*")

from agent_framework import Agent, FileCheckpointStorage, WorkflowBuilder  # noqa: E402
from agent_framework.openai import OpenAIChatCompletionClient  # noqa: E402
from agent_framework.orchestrations import SequentialBuilder  # noqa: E402


def _client() -> OpenAIChatCompletionClient:
    return OpenAIChatCompletionClient(
        model=os.environ["MODEL_NAME"],
        azure_endpoint=os.environ["APIM_URL"],
        api_version="2024-10-21",
        api_key=os.environ["APIM_KEY"],
        default_headers={
            "x-model-tier": os.environ.get("MODEL_TIER", "premium"),
        },
    )


def build_agents() -> tuple[Agent, Agent, Agent]:
    client = _client()
    triage = Agent(
        client=client,
        name="Triage",
        instructions=(
            "Classify the complaint as transactional, account-access, "
            "informational, or general. Output one line: "
            "'<category>: <one-sentence summary>'."
        ),
    )
    specialist = Agent(
        client=client,
        name="Specialist",
        instructions=(
            "You receive a triaged complaint. Draft a polite customer-facing "
            "reply (max 4 sentences) and propose two concrete next steps."
        ),
    )
    compliance = Agent(
        client=client,
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
        participants=[triage, specialist, compliance],
    ).build()

    result = await workflow.run(
        "Saldo saya hilang Rp 5 juta tanpa transaksi yang saya kenali. "
        "Tolong bantu segera."
    )
    # ``WorkflowRunResult.get_outputs()`` returns the final outputs.
    for output in result.get_outputs():
        print(output)


async def run_with_checkpoints() -> None:
    """Lower-level ``WorkflowBuilder`` with disk-backed checkpoints.

    Run once; kill the process during step 2; rerun with the same
    checkpoint dir to see the workflow resume from the last good step.
    """
    triage, specialist, compliance = build_agents()
    storage = FileCheckpointStorage(Path("./.checkpoints").resolve())

    # In 1.4.0, ``checkpoint_storage`` is a constructor kwarg on
    # ``WorkflowBuilder`` — the older fluent ``.with_checkpointing()``
    # method was removed.
    workflow = (
        WorkflowBuilder(start_executor=triage, checkpoint_storage=storage)
        .add_edge(triage, specialist)
        .add_edge(specialist, compliance)
        .build()
    )

    result = await workflow.run(
        "Aplikasi mobile banking saya keluar terus saat login. "
        "Sudah uninstall reinstall."
    )
    for output in result.get_outputs():
        print(output)


if __name__ == "__main__":
    # Toggle which flavor to run via env var so the docs can demo both.
    if os.environ.get("WORKFLOW_MODE") == "checkpoint":
        asyncio.run(run_with_checkpoints())
    else:
        asyncio.run(run_sequential())
