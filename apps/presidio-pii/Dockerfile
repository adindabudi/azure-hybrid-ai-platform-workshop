# Custom Presidio orchestrator container.
#
# What it adds on top of stock Presidio:
#   1. Indonesian PII recognizers (NIK, NPWP, Indonesian phone) registered
#      first-class in the analyzer.
#   2. Optional Azure AI Language Text Analytics PII recognizer wired in
#      through Presidio's RemoteRecognizer pattern. Activates only when
#      LANGUAGE_ENDPOINT and LANGUAGE_KEY env vars are present, so the
#      same image runs in "Presidio-only" or "Presidio + Language" mode.
#   3. A SINGLE /redact REST endpoint that bundles analyze + anonymize, so
#      APIM only needs ONE <send-request>. Stock Presidio ships analyzer
#      and anonymizer as two containers and APIM would otherwise need two
#      hops with marshalling in between.
#
# Image is intended to be pushed to the workshop ACR and pulled by the
# Deployment in deployment.yaml.

FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# System deps for spaCy / blis wheels on slim base.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

# spaCy model — large English model gives best NER recall for PERSON /
# LOCATION / ORG. ~750 MB; if you need to keep the image smaller, swap
# for en_core_web_sm (smaller, lower recall) and document the tradeoff.
RUN python -m spacy download en_core_web_lg

COPY recognizers/ ./recognizers/
COPY app.py ./app.py

# Drop privileges. UID 10001 matches the apps/content-safety-cpu nodeSelector
# pattern (no shared user collisions on the cluster).
RUN useradd -u 10001 -m presidio
USER 10001

EXPOSE 8080

# 2 workers × 4 threads is enough headroom for the workshop's load
# (≤ 25 concurrent attendee shells). For production, raise via env.
CMD ["gunicorn", "-b", "0.0.0.0:8080", \
     "--workers", "2", "--threads", "4", \
     "--timeout", "60", \
     "--access-logfile", "-", "--error-logfile", "-", \
     "app:app"]
