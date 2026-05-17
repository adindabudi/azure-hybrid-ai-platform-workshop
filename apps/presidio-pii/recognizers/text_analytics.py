"""Azure AI Language Text Analytics PII recognizer.

Wires the Azure AI Language Service (cloud or on-prem container) into
Presidio's analyzer pipeline as a `RemoteRecognizer`. This is the pattern
documented in the Presidio sample
`samples/python/integrating_with_external_services` and listed as a
first-party integration in
https://microsoft.github.io/presidio/analyzer/adding_recognizers
("Azure AI Language recognizer / Azure Health Data Services …").

Why a remote recognizer instead of calling Language directly from APIM:
  - Composition. Custom Indonesian recognizers (NIK / NPWP) merge with
    Language's PERSON / ADDRESS / EMAIL hits in one analyzer pass. APIM
    sees a single result set.
  - Failover. If Language is unreachable the analyzer still returns the
    Indonesian / built-in regex hits, so the gateway never opens up
    "no-mask" by accident.
  - Decoupling. APIM doesn't need to know Language even exists — wire,
    re-wire, or unwire Language without touching policy XML.

Activation: registered in app.py only when LANGUAGE_ENDPOINT and
LANGUAGE_KEY env vars are set. Same image runs in either mode.

Endpoint contract:
  POST {endpoint}/language/:analyze-text?api-version=2023-04-01
  Body: { kind: "PiiEntityRecognition", parameters: { modelVersion: "latest" },
          analysisInput: { documents: [{ id: "1", language: "en", text }] } }
  Returns documents[0].entities[] with category, offset, length,
  confidenceScore — directly mappable to Presidio's RecognizerResult.

Source for the API contract:
  https://learn.microsoft.com/azure/ai-services/language-service/personally-identifiable-information/quickstart
"""
from __future__ import annotations

import logging
from typing import List, Optional

import requests
from presidio_analyzer import RecognizerResult, RemoteRecognizer
from presidio_analyzer.nlp_engine import NlpArtifacts


logger = logging.getLogger(__name__)


# Azure AI Language PII categories → Presidio entity types. Kept explicit
# rather than passed through verbatim so the entity vocabulary stays small
# and the anonymizer's operator map (in app.py) does not need to grow
# every time Microsoft adds a category.
CATEGORY_MAP = {
    "Person":             "PERSON",
    "PersonType":         "PERSON",
    "Organization":       "ORGANIZATION",
    "Address":            "LOCATION",
    "Email":              "EMAIL_ADDRESS",
    "PhoneNumber":        "PHONE_NUMBER",
    "IPAddress":          "IP_ADDRESS",
    "URL":                "URL",
    "DateTime":           "DATE_TIME",
    "CreditCardNumber":   "CREDIT_CARD",
    "InternationalBankingAccountNumber": "IBAN_CODE",
    "Age":                "AGE",
    "USSocialSecurityNumber": "US_SSN",
}


class AzureLanguagePiiRecognizer(RemoteRecognizer):
    """Calls Azure AI Language analyze-text PII as a Presidio RemoteRecognizer."""

    SUPPORTED_ENTITIES = sorted(set(CATEGORY_MAP.values()))

    def __init__(
        self,
        endpoint: str,
        api_key: str,
        api_version: str = "2023-04-01",
        timeout_s: float = 5.0,
        min_confidence: float = 0.5,
    ) -> None:
        super().__init__(
            supported_entities=self.SUPPORTED_ENTITIES,
            name="AzureLanguagePiiRecognizer",
            supported_language="en",
            version="1.0",
        )
        self._endpoint = endpoint.rstrip("/")
        self._api_key = api_key
        self._api_version = api_version
        self._timeout_s = timeout_s
        self._min_confidence = min_confidence

    # RemoteRecognizer.load() is called once at registration time. The
    # entity list above is static for this PII task, so we have nothing
    # to fetch — keep it a no-op rather than burning a startup HTTP call.
    def load(self) -> None:
        return

    def get_supported_entities(self) -> List[str]:
        return list(self.SUPPORTED_ENTITIES)

    def analyze(
        self,
        text: str,
        entities: List[str],
        nlp_artifacts: Optional[NlpArtifacts] = None,
    ) -> List[RecognizerResult]:
        if not text:
            return []

        url = f"{self._endpoint}/language/:analyze-text?api-version={self._api_version}"
        body = {
            "kind": "PiiEntityRecognition",
            "parameters": {"modelVersion": "latest"},
            "analysisInput": {
                "documents": [
                    {"id": "1", "language": self.supported_language, "text": text}
                ]
            },
        }
        headers = {
            "Ocp-Apim-Subscription-Key": self._api_key,
            "Content-Type": "application/json",
        }

        try:
            resp = requests.post(url, json=body, headers=headers, timeout=self._timeout_s)
            resp.raise_for_status()
        except requests.RequestException as exc:
            # Fail-open on this recognizer only — the rest of the analyzer
            # (built-ins + Indonesian patterns) still runs and produces
            # results. The gateway therefore never silently passes PII;
            # at worst it loses Language's incremental coverage.
            logger.warning("Azure Language PII call failed: %s", exc)
            return []

        return self._to_recognizer_results(resp.json(), entities)

    def _to_recognizer_results(
        self, payload: dict, requested_entities: List[str]
    ) -> List[RecognizerResult]:
        out: List[RecognizerResult] = []
        documents = (payload.get("results") or {}).get("documents") or []
        if not documents:
            return out

        for entity in documents[0].get("entities", []):
            category = entity.get("category", "")
            mapped = CATEGORY_MAP.get(category)
            if mapped is None:
                continue
            if requested_entities and mapped not in requested_entities:
                continue
            score = float(entity.get("confidenceScore", 0.0))
            if score < self._min_confidence:
                continue
            offset = int(entity["offset"])
            length = int(entity["length"])
            out.append(
                RecognizerResult(
                    entity_type=mapped,
                    start=offset,
                    end=offset + length,
                    score=score,
                    analysis_explanation=None,
                )
            )
        return out
