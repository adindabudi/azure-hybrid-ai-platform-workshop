"""Single-shot Presidio orchestrator for the workshop AI gateway.

Exposes ONE endpoint, POST /redact, that:
  1. Runs `AnalyzerEngine.analyze()` against the input text
  2. Pipes the analyzer results into `AnonymizerEngine.anonymize()`
  3. Returns `{ text: <redacted>, entities: [...] }`

Why one endpoint instead of two (analyzer + anonymizer separately):
  APIM's `<send-request>` is the gateway's only way to call us. Two
  containers would force APIM to do analyze → marshal → anonymize, which
  doubles latency, complicates error handling, and forces APIM XML to
  hold per-entity operator config. We push all of that into Python here.

Custom recognizers always registered:
  - IndonesianNIK / NPWP / Phone / BankAccount  (recognizers.indonesian)

Optional recognizer (registered only if env vars present):
  - AzureLanguagePiiRecognizer  (recognizers.text_analytics)
    Activates when LANGUAGE_ENDPOINT and LANGUAGE_KEY are set. Endpoint
    can be either the cloud Language service or a `language-pii` AKS
    container (see apps/language-pii-cpu/).
"""
from __future__ import annotations

import logging
import os
from typing import Any, Dict

from flask import Flask, jsonify, request
from presidio_analyzer import AnalyzerEngine
from presidio_anonymizer import AnonymizerEngine
from presidio_anonymizer.entities import OperatorConfig

from recognizers.indonesian import ALL_INDONESIAN_RECOGNIZERS
from recognizers.text_analytics import AzureLanguagePiiRecognizer


logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s - %(message)s",
)
logger = logging.getLogger("presidio-pii")


# --- Engine setup (executed once at process startup) ------------------------

analyzer = AnalyzerEngine()  # Default NLP engine = spaCy en_core_web_lg

for recognizer in ALL_INDONESIAN_RECOGNIZERS:
    analyzer.registry.add_recognizer(recognizer)
logger.info("Registered %d Indonesian recognizers", len(ALL_INDONESIAN_RECOGNIZERS))

# Wire Azure AI Language only if explicitly configured. Env-driven so the
# same image runs in "Presidio-only" or "Presidio + Language" mode.
LANGUAGE_ENDPOINT = os.getenv("LANGUAGE_ENDPOINT", "").strip()
LANGUAGE_KEY = os.getenv("LANGUAGE_KEY", "").strip()
if LANGUAGE_ENDPOINT and LANGUAGE_KEY:
    analyzer.registry.add_recognizer(
        AzureLanguagePiiRecognizer(
            endpoint=LANGUAGE_ENDPOINT,
            api_key=LANGUAGE_KEY,
            min_confidence=float(os.getenv("LANGUAGE_MIN_CONFIDENCE", "0.5")),
        )
    )
    logger.info("AzureLanguagePiiRecognizer enabled → %s", LANGUAGE_ENDPOINT)
else:
    logger.info("AzureLanguagePiiRecognizer disabled (LANGUAGE_ENDPOINT/LANGUAGE_KEY not set)")

anonymizer = AnonymizerEngine()


# --- Anonymizer operator map ------------------------------------------------
# One bracketed marker per category. `DEFAULT` covers any entity Presidio
# discovers that we did not enumerate (e.g. a custom recognizer added later).
DEFAULT_OPERATORS: Dict[str, OperatorConfig] = {
    "DEFAULT":          OperatorConfig("replace", {"new_value": "[REDACTED]"}),
    "PERSON":           OperatorConfig("replace", {"new_value": "[PERSON-MASKED]"}),
    "ORGANIZATION":     OperatorConfig("replace", {"new_value": "[ORG-MASKED]"}),
    "LOCATION":         OperatorConfig("replace", {"new_value": "[LOCATION-MASKED]"}),
    "EMAIL_ADDRESS":    OperatorConfig("replace", {"new_value": "[EMAIL-MASKED]"}),
    "PHONE_NUMBER":     OperatorConfig("replace", {"new_value": "[PHONE-MASKED]"}),
    "IP_ADDRESS":       OperatorConfig("replace", {"new_value": "[IP-MASKED]"}),
    "URL":              OperatorConfig("replace", {"new_value": "[URL-MASKED]"}),
    "DATE_TIME":        OperatorConfig("keep"),  # Dates are usually safe; keep verbatim.
    "CREDIT_CARD":      OperatorConfig("replace", {"new_value": "[PAN-MASKED]"}),
    "IBAN_CODE":        OperatorConfig("replace", {"new_value": "[IBAN-MASKED]"}),
    "US_SSN":           OperatorConfig("replace", {"new_value": "[SSN-MASKED]"}),
    "AGE":              OperatorConfig("keep"),
    # Indonesian identifiers
    "ID_NIK":           OperatorConfig("replace", {"new_value": "[NIK-MASKED]"}),
    "ID_NPWP":          OperatorConfig("replace", {"new_value": "[NPWP-MASKED]"}),
    "ID_PHONE":         OperatorConfig("replace", {"new_value": "[PHONE-MASKED]"}),
    "ID_BANK_ACCOUNT":  OperatorConfig("replace", {"new_value": "[ACCT-MASKED]"}),
}


# --- Flask app --------------------------------------------------------------

app = Flask(__name__)

MAX_TEXT_BYTES = int(os.getenv("MAX_TEXT_BYTES", str(64 * 1024)))  # 64 KiB
DEFAULT_LANGUAGE = os.getenv("DEFAULT_LANGUAGE", "en")


@app.get("/healthz")
def healthz() -> Any:
    return jsonify({"status": "ok"})


@app.get("/supportedentities")
def supported_entities() -> Any:
    return jsonify(sorted(analyzer.get_supported_entities(language=DEFAULT_LANGUAGE)))


@app.post("/redact")
def redact() -> Any:
    """Run analyze → anonymize in one shot.

    Request body:
      { "text": "...", "language": "en"  (optional) }

    Response body:
      { "text": "<redacted>",
        "entities": [ { "type": "...", "start": n, "end": n, "score": f } ] }
    """
    payload = request.get_json(silent=True) or {}
    text = payload.get("text", "")
    if not isinstance(text, str):
        return jsonify({"error": "field 'text' must be a string"}), 400
    if len(text.encode("utf-8")) > MAX_TEXT_BYTES:
        # Hard ceiling to keep the analyzer call bounded; APIM should
        # truncate upstream long before we get here, but this is a guard.
        return jsonify({"error": f"text exceeds MAX_TEXT_BYTES ({MAX_TEXT_BYTES})"}), 413
    if not text:
        return jsonify({"text": "", "entities": []})

    language = payload.get("language") or DEFAULT_LANGUAGE

    analyzer_results = analyzer.analyze(text=text, language=language)
    anonymized = anonymizer.anonymize(
        text=text,
        analyzer_results=analyzer_results,
        operators=DEFAULT_OPERATORS,
    )

    return jsonify(
        {
            "text": anonymized.text,
            "entities": [
                {
                    "type": r.entity_type,
                    "start": r.start,
                    "end": r.end,
                    "score": round(r.score, 3),
                }
                for r in analyzer_results
            ],
        }
    )


if __name__ == "__main__":
    # Direct `python app.py` is for local dev only — production uses
    # gunicorn (see Dockerfile CMD).
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")))
