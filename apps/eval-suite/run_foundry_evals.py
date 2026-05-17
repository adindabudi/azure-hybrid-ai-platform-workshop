"""Run Azure AI Foundry-style evaluators on the M4 triage agent.

Uses the standalone ``azure-ai-evaluation`` SDK — these are the same
LLM-judge evaluators that Azure AI Foundry exposes in the portal, but
running locally so attendees don't need a Foundry project.

What this scores:

* **IntentResolution**     — did the agent understand and resolve the user's intent?
* **ToolCallAccuracy**     — were the right tools called with the right args?
* **TaskAdherence**        — did the agent stay on task per its instructions?
* **Relevance**            — is the response relevant to the query?
* **Groundedness**         — is the response grounded in the provided context/tool output?

Output is a JSON file you can diff in CI as a quality gate (see
``eval-gate.yml.example``).

API references:
* https://learn.microsoft.com/azure/foundry-classic/how-to/develop/agent-evaluate-sdk
* https://learn.microsoft.com/python/api/azure-ai-evaluation/azure.ai.evaluation
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from azure.ai.evaluation import (
    GroundednessEvaluator,
    IntentResolutionEvaluator,
    RelevanceEvaluator,
    TaskAdherenceEvaluator,
    ToolCallAccuracyEvaluator,
    evaluate,
)


HERE = Path(__file__).parent
DATA = HERE / "test_data.jsonl"
OUTPUT = HERE / "eval-results.json"


def _model_config() -> dict:
    """Judge model config — points at the workshop APIM endpoint.

    The judge can be a different model from the system under test. We
    use ``gpt-5-mini`` here for cost; switch to ``gpt-4.1`` or
    ``o3-mini`` for higher-fidelity reasoning evaluations.
    """
    return {
        "azure_endpoint": os.environ["APIM_URL"],
        "api_key": os.environ["APIM_KEY"],
        "azure_deployment": os.environ.get("JUDGE_MODEL", "gpt-5-mini"),
        "api_version": "2024-10-21",
    }


def _seed_test_data() -> None:
    """Write a small JSONL fixture if one isn't already present."""
    if DATA.exists():
        return
    rows = [
        {
            "query": "Halo, kartu ATM saya tertelan di Surabaya tadi malam.",
            "response": (
                "Saya sudah klasifikasikan ini sebagai keluhan transaksional "
                "dengan urgensi tinggi. Langkah berikutnya: blokir kartu via "
                "1500-XXX dan kunjungi cabang terdekat dengan KTP."
            ),
            "context": (
                "Tool classify_complaint returned {'category': 'transactional', "
                "'urgency': 'high'}."
            ),
            "ground_truth": (
                "Acknowledge, classify as transactional/high, instruct to block "
                "card and visit branch."
            ),
        },
        {
            "query": "Lupa password mobile banking, gimana resetnya?",
            "response": (
                "Reset bisa lewat menu 'Lupa Password' di aplikasi, atau hubungi "
                "call center. Pastikan punya KTP dan nomor rekening siap."
            ),
            "context": (
                "Tool classify_complaint returned {'category': 'account-access', "
                "'urgency': 'high'}."
            ),
            "ground_truth": (
                "Account-access flow: in-app reset or call center, with ID."
            ),
        },
        {
            "query": "Saldo saya berapa ya?",
            "response": (
                "Untuk cek saldo silakan login ke mobile banking, ATM, atau call "
                "center 1500-XXX. Saya tidak bisa lihat saldo dari sini."
            ),
            "context": (
                "Tool classify_complaint returned {'category': 'informational', "
                "'urgency': 'low'}."
            ),
            "ground_truth": "Direct customer to self-service balance channels.",
        },
    ]
    with DATA.open("w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")


def main() -> int:
    _seed_test_data()
    cfg = _model_config()

    # Each evaluator is configured with the judge model. The `evaluate`
    # function streams every row of test data through every evaluator
    # and writes a consolidated JSON output.
    #
    # Token-budget note: every evaluator costs ~150-400 tokens per row.
    # Running all five on N rows at once burns 5 * 400 * N tokens in a
    # single minute, which trips the APIM `llm-token-limit` (default
    # 5000 TPM in the workshop bundle, 500 TPM in earlier revisions)
    # and the evaluator silently gets `null` for the throttled rows.
    #
    # To stay within budget we run the evaluators in two batches with a
    # cooldown in between. Skip batching by setting `EVAL_BATCH=0`.
    all_evaluators = {
        "intent_resolution": IntentResolutionEvaluator(model_config=cfg),
        "tool_call_accuracy": ToolCallAccuracyEvaluator(model_config=cfg),
        "task_adherence": TaskAdherenceEvaluator(model_config=cfg),
        "relevance": RelevanceEvaluator(model_config=cfg),
        "groundedness": GroundednessEvaluator(model_config=cfg),
    }

    if os.environ.get("EVAL_BATCH", "1") == "1":
        # Two batches keep peak TPM under ~1500 even on a tight budget.
        batches = [
            {
                "intent_resolution": all_evaluators["intent_resolution"],
                "task_adherence":    all_evaluators["task_adherence"],
                "tool_call_accuracy": all_evaluators["tool_call_accuracy"],
            },
            {
                "relevance":     all_evaluators["relevance"],
                "groundedness":  all_evaluators["groundedness"],
            },
        ]
    else:
        batches = [all_evaluators]

    cooldown = int(os.environ.get("EVAL_COOLDOWN_SEC", "65"))
    merged_metrics: dict[str, object] = {}
    merged_rows: list[dict] = []

    for i, batch in enumerate(batches, start=1):
        out_path = OUTPUT.with_suffix(f".batch{i}.json") if len(batches) > 1 else OUTPUT
        print(f"\n--- Batch {i}/{len(batches)} :: {', '.join(batch.keys())} ---")
        result = evaluate(
            data=str(DATA),
            evaluators=batch,
            output_path=str(out_path),
        )
        merged_metrics.update(result.get("metrics", {}))
        merged_rows.extend(result.get("rows", []))

        if i < len(batches) and cooldown > 0:
            print(f"  (cooldown {cooldown}s before next batch to let TPM window slide)")
            time.sleep(cooldown)

    # Write the merged top-level file.
    OUTPUT.write_text(json.dumps(
        {"metrics": merged_metrics, "rows": merged_rows},
        indent=2, default=str,
    ), encoding="utf-8")

    metrics = merged_metrics
    print("\n=== Evaluation summary ===")
    for name, value in sorted(metrics.items()):
        print(f"  {name}: {value}")
    print(f"\nFull report: {OUTPUT}")

    # Hard fail if any *_pass_rate metric drops below the gate.
    threshold = float(os.environ.get("EVAL_PASS_THRESHOLD", "0.7"))
    failures = [
        f"{n}={v}"
        for n, v in metrics.items()
        if n.endswith(".pass_rate") and isinstance(v, (int, float)) and v < threshold
    ]
    if failures:
        print(f"\nFAIL: pass-rate below {threshold} for: {', '.join(failures)}")
        return 1
    print(f"\nOK: all pass-rates >= {threshold}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
