# StockPulse (stock-tracker) image. Built by host/scripts/15-stockpulse.sh from `git archive` of the
# commit in stockpulse/SOURCE (build context: src/ = that commit, nothing else).
# Reproducible: base image pinned by digest, Python packages installed with --require-hashes.
FROM docker.io/library/python:3.13.18-slim-trixie@sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
    TZ=Europe/Stockholm
RUN groupadd -g 10010 stockpulse && useradd -u 10010 -g 10010 -M -d /nonexistent -s /usr/sbin/nologin stockpulse
COPY src/requirements.lock /app/requirements.lock
RUN pip install --require-hashes --no-deps -r /app/requirements.lock \
 && python -c "import yfinance, pandas, google.auth, requests, dotenv" \
 && test -e /usr/share/zoneinfo/Europe/Stockholm
# Only the application files; not the repo's docs/backfill helpers' data (there is none) or .git.
COPY src/*.py src/stocks.txt /app/
WORKDIR /app
USER 10010:10010
# Data lives outside the image: /data (history.db), /reports (report*.html + reports/).
# HOME/XDG cache -> /tmp (tmpfs): yfinance's cookie/tz cache is disposable.
ENV STOCKPULSE_DATA_DIR=/data STOCKPULSE_REPORT_DIR=/reports HOME=/tmp XDG_CACHE_HOME=/tmp/cache \
    STOCKPULSE_FCM_KEY=/run/secrets/stockpulse/firebase-service-account.json
CMD ["python", "serve.py"]
