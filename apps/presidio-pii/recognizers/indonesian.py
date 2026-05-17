"""Indonesian PII recognizers for Presidio.

These are first-party Indonesian regulated identifiers we cannot expect any
upstream NER model (spaCy, Azure AI Language) to know. We register them as
PatternRecognizer subclasses so they participate in Presidio's standard
analyze → anonymize flow alongside built-ins (PERSON, EMAIL, PHONE_NUMBER,
CREDIT_CARD, etc.).

Sources:
  - NIK format          : Permendagri 7/2019 (16 digit numeric)
  - NPWP unified format : DJP PER-04/PJ/2020 + 16-digit unified rollout 2024
  - MSISDN ID phone     : ITU-T E.164 + Kominfo numbering plan (+62 / 0)
"""
from presidio_analyzer import Pattern, PatternRecognizer


# --- NIK / KTP (Nomor Induk Kependudukan) -----------------------------------
# Exactly 16 digits. Negative look-arounds via (?<![0-9])...(?![0-9]) keep us
# from matching the middle of a longer number string (e.g. an order ID).
NIK_RECOGNIZER = PatternRecognizer(
    supported_entity="ID_NIK",
    name="IndonesianNIKRecognizer",
    patterns=[
        Pattern(
            name="nik_16_digit",
            regex=r"(?<![0-9])\d{16}(?![0-9])",
            score=0.7,
        ),
    ],
    context=["nik", "ktp", "kependudukan", "id card"],
    supported_language="en",
)


# --- NPWP (Nomor Pokok Wajib Pajak) -----------------------------------------
# Two formats are in active circulation as of May 2026:
#   1. Legacy 15-digit, formatted   NN.NNN.NNN.N-NNN.NNN
#   2. Unified 16-digit (post-2024) — same as NIK for individuals, or 16
#      digits for legal entities. We rely on the legacy formatted variant
#      here and let NIK_RECOGNIZER cover the unified individual case.
NPWP_RECOGNIZER = PatternRecognizer(
    supported_entity="ID_NPWP",
    name="IndonesianNPWPRecognizer",
    patterns=[
        Pattern(
            name="npwp_15_formatted",
            regex=r"(?<![0-9])\d{2}\.\d{3}\.\d{3}\.\d-\d{3}\.\d{3}(?![0-9])",
            score=0.85,
        ),
    ],
    context=["npwp", "tax id", "wajib pajak", "djp"],
    supported_language="en",
)


# --- Indonesian phone number ------------------------------------------------
# +62 or 0 prefix, then leading 8 (mobile) or 2-7 (fixed-line area codes),
# total length 9-13 digits. We deliberately do NOT collapse spaces / dashes
# because the typical model output is digits-run; if you need richer parsing
# wire in libphonenumber via a Python recognizer.
PHONE_ID_RECOGNIZER = PatternRecognizer(
    supported_entity="ID_PHONE",
    name="IndonesianPhoneRecognizer",
    patterns=[
        # Mobile: +62 8xx ........ or 08xx ........
        Pattern(
            name="phone_id_mobile",
            regex=r"(?<![0-9])(?:\+62|0)8\d{8,11}(?![0-9])",
            score=0.7,
        ),
        # Fixed-line (rough heuristic): +62 then area code then 6-9 digits
        Pattern(
            name="phone_id_fixed",
            regex=r"(?<![0-9])(?:\+62|0)[2-7]\d{6,10}(?![0-9])",
            score=0.55,
        ),
    ],
    context=["telepon", "hp", "handphone", "phone", "wa", "whatsapp"],
    supported_language="en",
)


# --- Indonesian bank account ------------------------------------------------
# Indonesian bank accounts are usually 10-16 digits. This is a low-confidence
# recognizer because the same length range catches order ids / loan numbers.
# Score 0.4 → Presidio default decision_threshold (0.0 by default but commonly
# raised to 0.4-0.5) means it surfaces but downstream callers can choose to
# ignore. Anonymization still triggers on it.
BANK_ACCOUNT_RECOGNIZER = PatternRecognizer(
    supported_entity="ID_BANK_ACCOUNT",
    name="IndonesianBankAccountRecognizer",
    patterns=[
        Pattern(
            name="bank_account_10_16",
            regex=r"(?<![0-9])\d{10,16}(?![0-9])",
            score=0.4,
        ),
    ],
    context=["rekening", "bank", "norek", "account", "transfer"],
    supported_language="en",
)


ALL_INDONESIAN_RECOGNIZERS = [
    NIK_RECOGNIZER,
    NPWP_RECOGNIZER,
    PHONE_ID_RECOGNIZER,
    BANK_ACCOUNT_RECOGNIZER,
]
