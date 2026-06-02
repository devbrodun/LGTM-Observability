#!/bin/bash
# ============================================================================
# install.sh – Installs, configures, and starts the full vuln-observability
# stack as native systemd services on Ubuntu.
#
# Usage:
#   sudo SLACK_WEBHOOK_URL="https://hooks.slack.com/..." GITHUB_PAT="ghp_..." ./systemd/install.sh
#
# Idempotent: safe to run multiple times on the same server.
# Must be run from the repository root directory.
# ============================================================================
set -euo pipefail

TOTAL_STEPS=11
CURRENT_STEP=0
progress() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  local pct=$((CURRENT_STEP * 100 / TOTAL_STEPS))
  echo ""
  echo "==> [${CURRENT_STEP}/${TOTAL_STEPS}] (${pct}%) $1"
}

# ============================================================================
# Section 0 – Strict mode and variables
# ============================================================================
PROMETHEUS_VERSION=2.51.0
LOKI_VERSION=2.9.5
TEMPO_VERSION=2.4.1
NODE_EXPORTER_VERSION=1.7.0
BLACKBOX_VERSION=0.24.0
ALERTMANAGER_VERSION=0.27.0
OTEL_VERSION=0.99.0
GH_EXPORTER_VERSION=${GH_EXPORTER_VERSION:-}
GH_EXPORTER_FAIL_REASON=""

INSTALL_DIR=/usr/local/bin
CONFIG_BASE=/etc
DATA_BASE=/var/lib
REPO_DIR=$(pwd)

SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL:-https://hooks.slack.com/services/PLACEHOLDER}
SLACK_BOT_NAME=${SLACK_BOT_NAME:-vuln-bot}
ALERT_EMAIL_TO=${ALERT_EMAIL_TO:-alerts@example.com}
SMTP_SMARTHOST=${SMTP_SMARTHOST:-smtp.example.com:587}
SMTP_FROM=${SMTP_FROM:-alerts@example.com}
SMTP_USERNAME=${SMTP_USERNAME:-alerts@example.com}
SMTP_PASSWORD=${SMTP_PASSWORD:-placeholder_password}
GITHUB_PAT=${GITHUB_PAT:-placeholder_token}
GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-}
GITHUB_REPO_URL=${GITHUB_REPO_URL:-}
VM_HOST=${VM_HOST:-}
GRAFANA_EXTERNAL_URL=${GRAFANA_EXTERNAL_URL:-}
PROMETHEUS_EXTERNAL_URL=${PROMETHEUS_EXTERNAL_URL:-}
ALERTMANAGER_EXTERNAL_URL=${ALERTMANAGER_EXTERNAL_URL:-}
BLACKBOX_HTTP_TARGETS=${BLACKBOX_HTTP_TARGETS:-}
BLACKBOX_SSL_TARGETS=${BLACKBOX_SSL_TARGETS:-}

if [ -z "${GRAFANA_EXTERNAL_URL}" ] && [ -n "${VM_HOST}" ]; then
  GRAFANA_EXTERNAL_URL="http://${VM_HOST}:3000"
fi
if [ -z "${PROMETHEUS_EXTERNAL_URL}" ] && [ -n "${VM_HOST}" ]; then
  PROMETHEUS_EXTERNAL_URL="http://${VM_HOST}:9090"
fi
if [ -z "${ALERTMANAGER_EXTERNAL_URL}" ] && [ -n "${VM_HOST}" ]; then
  ALERTMANAGER_EXTERNAL_URL="http://${VM_HOST}:9093"
fi
if [ -z "${GITHUB_REPO_URL}" ] && [ -n "${GITHUB_REPOSITORY}" ]; then
  GITHUB_REPO_URL="https://github.com/${GITHUB_REPOSITORY}"
fi

echo "==> Starting vuln-observability installation from: $REPO_DIR"
echo "==> Progress tracking enabled (${TOTAL_STEPS} total steps)"

# ============================================================================
# Section 1 – System preparation
# ============================================================================
progress "Preparing system packages and Grafana repo"
apt-get update -y
apt-get install -y curl wget tar unzip python3 python3-pip python3-venv adduser libfontconfig1 apt-transport-https software-properties-common


# Add Grafana apt repository and install grafana=10.4.2
if ! dpkg -l | grep -q "^ii  grafana "; then
  wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor > /usr/share/keyrings/grafana.gpg
  echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" | tee /etc/apt/sources.list.d/grafana.list
  apt-get update -y
  apt-get install -y grafana=10.4.2
fi

systemctl daemon-reload

# ============================================================================
# Section 2 – Create system users (idempotent)
# ============================================================================
progress "Creating system users"
for user in prometheus loki tempo node_exporter blackbox alertmanager otel ghexporter demoservice; do
  if ! id -u "$user" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /bin/false "$user"
    echo "  Created user: $user"
  fi
done

# ============================================================================
# Section 3 – Create data and config directories
# ============================================================================
progress "Creating data and config directories"
for service in prometheus loki tempo alertmanager; do
  mkdir -p ${CONFIG_BASE}/${service}
  mkdir -p ${DATA_BASE}/${service}
done

mkdir -p /etc/prometheus/rules
mkdir -p /etc/alertmanager/templates
mkdir -p /var/lib/grafana/dashboards
mkdir -p /etc/grafana/provisioning/datasources
mkdir -p /etc/grafana/provisioning/dashboards
mkdir -p /etc/grafana/provisioning/notifiers
mkdir -p /etc/grafana/provisioning/plugins
mkdir -p /etc/grafana/provisioning/alerting
mkdir -p ${CONFIG_BASE}/otel-collector
mkdir -p ${CONFIG_BASE}/blackbox-exporter
mkdir -p ${CONFIG_BASE}/github-actions-exporter
mkdir -p /var/log/demo-service
mkdir -p /opt/demo-service

# ============================================================================
# Section 4 – Download and install binaries
# ============================================================================
progress "Downloading and installing binaries"
TMP_DIR=$(mktemp -d -p /var/tmp)
cd "$TMP_DIR"

# Prometheus
if [ ! -f "${INSTALL_DIR}/prometheus" ]; then
  echo "  Downloading Prometheus ${PROMETHEUS_VERSION}..."
  wget -q "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz"
  tar xf prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
  cp prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus ${INSTALL_DIR}/
  cp prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool ${INSTALL_DIR}/
  chmod 755 ${INSTALL_DIR}/prometheus ${INSTALL_DIR}/promtool
  rm -rf prometheus-${PROMETHEUS_VERSION}.linux-amd64*
  echo "  [OK] prometheus installed"
fi

# Loki
if [ ! -f "${INSTALL_DIR}/loki" ]; then
  echo "  Downloading Loki ${LOKI_VERSION}..."
  wget -q "https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-amd64.zip"
  unzip -q loki-linux-amd64.zip loki-linux-amd64
  mv loki-linux-amd64 loki
  cp loki ${INSTALL_DIR}/
  chmod 755 ${INSTALL_DIR}/loki
  rm -f loki loki-linux-amd64.zip
  echo "  [OK] loki installed"
fi

# Tempo
if [ ! -f "${INSTALL_DIR}/tempo" ]; then
  echo "  Downloading Tempo ${TEMPO_VERSION}..."
  wget -q "https://github.com/grafana/tempo/releases/download/v${TEMPO_VERSION}/tempo_${TEMPO_VERSION}_linux_amd64.tar.gz"
  tar xf tempo_${TEMPO_VERSION}_linux_amd64.tar.gz tempo
  cp tempo ${INSTALL_DIR}/
  chmod 755 ${INSTALL_DIR}/tempo
  rm -f tempo tempo_${TEMPO_VERSION}_linux_amd64.tar.gz
  echo "  [OK] tempo installed"
fi

# Node Exporter
if [ ! -f "${INSTALL_DIR}/node_exporter" ]; then
  echo "  Downloading Node Exporter ${NODE_EXPORTER_VERSION}..."
  wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
  tar xf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
  cp node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter ${INSTALL_DIR}/
  chmod 755 ${INSTALL_DIR}/node_exporter
  rm -rf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64*
  echo "  [OK] node_exporter installed"
fi

# Blackbox Exporter
if [ ! -f "${INSTALL_DIR}/blackbox_exporter" ]; then
  echo "  Downloading Blackbox Exporter ${BLACKBOX_VERSION}..."
  wget -q "https://github.com/prometheus/blackbox_exporter/releases/download/v${BLACKBOX_VERSION}/blackbox_exporter-${BLACKBOX_VERSION}.linux-amd64.tar.gz"
  tar xf blackbox_exporter-${BLACKBOX_VERSION}.linux-amd64.tar.gz
  cp blackbox_exporter-${BLACKBOX_VERSION}.linux-amd64/blackbox_exporter ${INSTALL_DIR}/
  chmod 755 ${INSTALL_DIR}/blackbox_exporter
  rm -rf blackbox_exporter-${BLACKBOX_VERSION}.linux-amd64*
  echo "  [OK] blackbox_exporter installed"
fi

# Alertmanager
if [ ! -f "${INSTALL_DIR}/alertmanager" ]; then
  echo "  Downloading Alertmanager ${ALERTMANAGER_VERSION}..."
  wget -q "https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz"
  tar xf alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz
  cp alertmanager-${ALERTMANAGER_VERSION}.linux-amd64/alertmanager ${INSTALL_DIR}/
  cp alertmanager-${ALERTMANAGER_VERSION}.linux-amd64/amtool ${INSTALL_DIR}/
  chmod 755 ${INSTALL_DIR}/alertmanager ${INSTALL_DIR}/amtool
  rm -rf alertmanager-${ALERTMANAGER_VERSION}.linux-amd64*
  echo "  [OK] alertmanager installed"
fi

# OTel Collector
if [ ! -f "${INSTALL_DIR}/otelcol-contrib" ]; then
  echo "  Downloading OTel Collector ${OTEL_VERSION}..."
  if wget -q "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol-contrib_${OTEL_VERSION}_linux_amd64.tar.gz"; then
    tar xf otelcol-contrib_${OTEL_VERSION}_linux_amd64.tar.gz otelcol-contrib
    cp otelcol-contrib ${INSTALL_DIR}/
    chmod 755 ${INSTALL_DIR}/otelcol-contrib
    rm -f otelcol-contrib otelcol-contrib_${OTEL_VERSION}_linux_amd64.tar.gz
    echo "  [OK] otelcol-contrib installed"
  else
    echo "  [WARN] Failed to download otelcol-contrib – otel-collector service will not start"
  fi
fi

# GitHub Actions Exporter – required for DORA dashboard
if [ ! -f "${INSTALL_DIR}/github-actions-exporter" ]; then
  echo "  Downloading GitHub Actions Exporter..."
  RELEASE_JSON=$(mktemp -p /var/tmp gha-release.XXXXXX.json)
  if [ -n "${GH_EXPORTER_VERSION}" ]; then
    API_URL="https://api.github.com/repos/Labbs/github-actions-exporter/releases/tags/v${GH_EXPORTER_VERSION}"
    if ! curl -fsSL "$API_URL" -o "$RELEASE_JSON"; then
      echo "  [WARN] Tag v${GH_EXPORTER_VERSION} not found; falling back to latest release."
      API_URL="https://api.github.com/repos/Labbs/github-actions-exporter/releases/latest"
      if ! curl -fsSL "$API_URL" -o "$RELEASE_JSON"; then
        GH_EXPORTER_FAIL_REASON="release metadata request failed (${API_URL})"
        echo "  [FATAL] Installation failed: github-actions-exporter ${GH_EXPORTER_FAIL_REASON}"
        rm -f "$RELEASE_JSON"
        exit 1
      fi
    fi
  else
    API_URL="https://api.github.com/repos/Labbs/github-actions-exporter/releases/latest"
    if ! curl -fsSL "$API_URL" -o "$RELEASE_JSON"; then
      GH_EXPORTER_FAIL_REASON="release metadata request failed (${API_URL})"
      echo "  [FATAL] Installation failed: github-actions-exporter ${GH_EXPORTER_FAIL_REASON}"
      rm -f "$RELEASE_JSON"
      exit 1
    fi
  fi

  ASSET_URL=$(
    python3 - "$RELEASE_JSON" <<'PY'
import json, re, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
assets = data.get("assets", [])

# Priority order: prefer named archive with OS/arch, then bare binary.
# Explicitly skip checksum files (.md5, .sha256, .sha512, etc.).
patterns = [
    re.compile(r"linux.*(amd64|x86_64|x64).*\.(tar\.gz|tgz|zip)$", re.I),
    re.compile(r"linux.*(amd64|x86_64|x64)$", re.I),
    # FIX: v1.9.0 ships a single raw binary named exactly "github-actions-exporter"
    # with no OS/arch suffix and no archive extension. Match it directly,
    # but exclude checksum sidecar files (.md5, .sha256, .sha512, etc.).
    re.compile(r"^github-actions-exporter$", re.I),
]
CHECKSUM_SUFFIXES = (".md5", ".sha256", ".sha512", ".sha1", ".asc", ".sig")

for p in patterns:
    for a in assets:
        name = a.get("name", "")
        url  = a.get("browser_download_url", "")
        if any(name.lower().endswith(s) for s in CHECKSUM_SUFFIXES):
            continue
        if p.search(name) and url:
            print(url)
            raise SystemExit(0)
raise SystemExit(1)
PY
  ) || true

  rm -f "$RELEASE_JSON"
  if [ -z "$ASSET_URL" ]; then
    GH_EXPORTER_FAIL_REASON="no Linux amd64/x64 release asset found"
    echo "  [FATAL] Installation failed: github-actions-exporter ${GH_EXPORTER_FAIL_REASON}"
    echo "  [ERROR] No Linux amd64 exporter asset found in Labbs/github-actions-exporter releases."
    exit 1
  fi

  ARCHIVE=$(basename "$ASSET_URL")
  EXTRACT_DIR=$(mktemp -d -p /var/tmp gha-exporter.XXXXXX)
  echo "  [INFO] github-actions-exporter asset selected: $ASSET_URL"

  if ! curl -fL "$ASSET_URL" -o "$ARCHIVE"; then
    GH_EXPORTER_FAIL_REASON="asset download failed (${ASSET_URL})"
    echo "  [FATAL] Installation failed: github-actions-exporter ${GH_EXPORTER_FAIL_REASON}"
    rm -f "$ARCHIVE"
    rm -rf "$EXTRACT_DIR"
    exit 1
  fi

  case "$ARCHIVE" in
    *.zip)
      unzip -q "$ARCHIVE" -d "$EXTRACT_DIR" || {
        GH_EXPORTER_FAIL_REASON="invalid zip archive ($ARCHIVE)"
        echo "  [FATAL] Installation failed: github-actions-exporter ${GH_EXPORTER_FAIL_REASON}"
        rm -f "$ARCHIVE"; rm -rf "$EXTRACT_DIR"; exit 1
      }
      BIN_PATH=$(find "$EXTRACT_DIR" -type f \( -name "github-actions-exporter" -o -name "github-actions-exporter_*" \) | head -1 || true)
      ;;
    *.tar.gz|*.tgz)
      tar xf "$ARCHIVE" -C "$EXTRACT_DIR" || {
        GH_EXPORTER_FAIL_REASON="invalid tar archive ($ARCHIVE)"
        echo "  [FATAL] Installation failed: github-actions-exporter ${GH_EXPORTER_FAIL_REASON}"
        rm -f "$ARCHIVE"; rm -rf "$EXTRACT_DIR"; exit 1
      }
      BIN_PATH=$(find "$EXTRACT_DIR" -type f \( -name "github-actions-exporter" -o -name "github-actions-exporter_*" \) | head -1 || true)
      ;;
    *)
      # FIX: Raw binary asset (e.g. v1.9.0) – no extraction needed.
      # The downloaded file IS the binary; set BIN_PATH directly instead
      # of searching an empty EXTRACT_DIR (which would always fail).
      BIN_PATH="$ARCHIVE"
      ;;
  esac

  if [ -z "$BIN_PATH" ]; then
    GH_EXPORTER_FAIL_REASON="binary not found in downloaded asset ($ARCHIVE)"
    echo "  [FATAL] Installation failed: github-actions-exporter ${GH_EXPORTER_FAIL_REASON}"
    rm -f "$ARCHIVE"
    rm -rf "$EXTRACT_DIR"
    exit 1
  fi

  cp "$BIN_PATH" "${INSTALL_DIR}/github-actions-exporter"
  chmod 755 "${INSTALL_DIR}/github-actions-exporter"
  rm -f "$ARCHIVE"
  rm -rf "$EXTRACT_DIR"
  echo "  [OK] github-actions-exporter installed"
fi

cd "$REPO_DIR"
rm -rf "$TMP_DIR"

# ============================================================================
# Section 5 – Copy config files from repo to system paths
# ============================================================================
progress "Copying configuration files"
cp "${REPO_DIR}/prometheus/prometheus.yml"            /etc/prometheus/prometheus.yml
cp "${REPO_DIR}/prometheus/blackbox.yml"              /etc/blackbox-exporter/config.yml
cp -r "${REPO_DIR}/prometheus/rules/."               /etc/prometheus/rules/
cp "${REPO_DIR}/loki/loki-config.yml"                /etc/loki/loki-config.yml
cp "${REPO_DIR}/tempo/tempo-config.yml"              /etc/tempo/tempo-config.yml
cp "${REPO_DIR}/alertmanager/alertmanager.yml"       /etc/alertmanager/alertmanager.yml
cp -r "${REPO_DIR}/alertmanager/templates/."         /etc/alertmanager/templates/
cp "${REPO_DIR}/otel-collector/otel-collector-config.yml" /etc/otel-collector/config.yml
cp -r "${REPO_DIR}/grafana/provisioning/."           /etc/grafana/provisioning/
cp -r "${REPO_DIR}/grafana/dashboards/"*.json        /var/lib/grafana/dashboards/

echo "==> Setting directory ownership..."
chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
chown -R loki:loki             /etc/loki /var/lib/loki
chown -R tempo:tempo           /etc/tempo /var/lib/tempo
chown -R alertmanager:alertmanager /etc/alertmanager /var/lib/alertmanager
chown -R blackbox:blackbox     /etc/blackbox-exporter
chown -R otel:otel             /etc/otel-collector
chown -R ghexporter:ghexporter /etc/github-actions-exporter
chown -R grafana:grafana       /etc/grafana /var/lib/grafana

# ============================================================================
# Section 6 – Substitute environment variables in configs
# ============================================================================
progress "Substituting environment variables"

sed -i "s|https://hooks.slack.com/services/PLACEHOLDER|${SLACK_WEBHOOK_URL}|g" /etc/alertmanager/alertmanager.yml
sed -i "s|__SLACK_BOT_NAME__|${SLACK_BOT_NAME}|g" /etc/alertmanager/alertmanager.yml
sed -i "s|__ALERT_EMAIL_TO__|${ALERT_EMAIL_TO}|g" /etc/alertmanager/alertmanager.yml
sed -i "s|__SMTP_SMARTHOST__|${SMTP_SMARTHOST}|g" /etc/alertmanager/alertmanager.yml
sed -i "s|__SMTP_FROM__|${SMTP_FROM}|g" /etc/alertmanager/alertmanager.yml
sed -i "s|__SMTP_USERNAME__|${SMTP_USERNAME}|g" /etc/alertmanager/alertmanager.yml
sed -i "s|__SMTP_PASSWORD__|${SMTP_PASSWORD}|g" /etc/alertmanager/alertmanager.yml
sed -i "s|__GRAFANA_EXTERNAL_URL__|${GRAFANA_EXTERNAL_URL}|g" /etc/alertmanager/templates/slack.tmpl
sed -i "s|__GRAFANA_EXTERNAL_URL__|${GRAFANA_EXTERNAL_URL}|g" /etc/alertmanager/templates/email.tmpl
sed -i "s|__ALERTMANAGER_EXTERNAL_URL__|${ALERTMANAGER_EXTERNAL_URL}|g" /etc/alertmanager/alertmanager.yml
sed -i "s|__GITHUB_REPO_URL__|${GITHUB_REPO_URL}|g" /etc/prometheus/rules/*.yml
sed -i "s|__VM_HOST__|${VM_HOST}|g" /etc/prometheus/prometheus.yml

if [ -n "${BLACKBOX_HTTP_TARGETS}" ] && [ -n "${BLACKBOX_SSL_TARGETS}" ]; then
  echo "==> Rendering blackbox targets from deploy variables..."
  export BLACKBOX_HTTP_TARGETS BLACKBOX_SSL_TARGETS
  python3 - <<'PY'
import os
import re

path = "/etc/prometheus/prometheus.yml"
http_targets = [x.strip() for x in os.environ.get("BLACKBOX_HTTP_TARGETS", "").split(",") if x.strip()]
ssl_targets = [x.strip() for x in os.environ.get("BLACKBOX_SSL_TARGETS", "").split(",") if x.strip()]

with open(path, "r", encoding="utf-8") as f:
    text = f.read()

def build_block(items):
    return "\n".join([f"          - {item}" for item in items])

http_block = build_block(http_targets)
ssl_block = build_block(ssl_targets)

text, n1 = re.subn(
    r"(?ms)([ \t]*# BLACKBOX_HTTP_TARGETS_START\n).*?([ \t]*# BLACKBOX_HTTP_TARGETS_END)",
    r"\1" + http_block + "\n" + r"\2",
    text,
)
text, n2 = re.subn(
    r"(?ms)([ \t]*# BLACKBOX_SSL_TARGETS_START\n).*?([ \t]*# BLACKBOX_SSL_TARGETS_END)",
    r"\1" + ssl_block + "\n" + r"\2",
    text,
)

if n1 != 1 or n2 != 1:
    raise SystemExit("Failed to render blackbox target blocks in prometheus.yml")

with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PY
fi

if [ -n "${VM_HOST}" ]; then
  echo "==> Rewriting hardcoded host references to VM_HOST=${VM_HOST}..."
  sed -i "s|3\.219\.30\.122|${VM_HOST}|g; s|3\.239\.26\.39|${VM_HOST}|g" /etc/alertmanager/alertmanager.yml || true
  sed -i "s|3\.219\.30\.122|${VM_HOST}|g; s|3\.239\.26\.39|${VM_HOST}|g" /etc/alertmanager/templates/slack.tmpl || true
  sed -i "s|3\.219\.30\.122|${VM_HOST}|g; s|3\.239\.26\.39|${VM_HOST}|g" /etc/alertmanager/templates/email.tmpl || true
fi

# ============================================================================
# Section 7 – Install and configure demo service
# ============================================================================
progress "Installing demo service"
cp "${REPO_DIR}/demo-service/app.py"           /opt/demo-service/
cp "${REPO_DIR}/demo-service/requirements.txt" /opt/demo-service/

if [ ! -d /opt/demo-service/venv ]; then
  python3 -m venv /opt/demo-service/venv
fi
/opt/demo-service/venv/bin/pip install --quiet --upgrade -r /opt/demo-service/requirements.txt

chown -R demoservice:demoservice /opt/demo-service

# ============================================================================
# Section 8 – Install systemd unit files
# ============================================================================
progress "Installing systemd unit files"
cp "${REPO_DIR}/systemd/"*.service /etc/systemd/system/

# FIX: This sed must run AFTER the service files are copied above.
# Previously it was in Section 6 before the cp, causing the script to
# exit immediately under set -euo pipefail with "No such file or directory".
sed -i "s|__PROMETHEUS_EXTERNAL_URL__|${PROMETHEUS_EXTERNAL_URL}|g" /etc/systemd/system/prometheus.service

if [ "${GITHUB_PAT}" = "placeholder_token" ] || [ -z "${GITHUB_REPOSITORY}" ]; then
  GH_EXPORTER_FAIL_REASON="missing required env (GITHUB_PAT or GITHUB_REPOSITORY)"
  echo "  [FATAL] Installation failed: github-actions-exporter ${GH_EXPORTER_FAIL_REASON}"
  echo "  [ERROR] github-actions-exporter requires both GITHUB_PAT and GITHUB_REPOSITORY."
  exit 1
fi

{
  echo "GITHUB_TOKEN=${GITHUB_PAT}"
  echo "GITHUB_REPOS=${GITHUB_REPOSITORY}"
  echo "GITHUB_REPOSITORY=${GITHUB_REPOSITORY}"
  echo "PORT=9999"
} > /etc/github-actions-exporter/env
chmod 600 /etc/github-actions-exporter/env
chown ghexporter:ghexporter /etc/github-actions-exporter/env

systemctl daemon-reload

# ============================================================================
# Section 9 – Enable and start all services
# ============================================================================
progress "Enabling and starting services"

SERVICES="grafana-server prometheus loki tempo node-exporter blackbox-exporter alertmanager otel-collector github-actions-exporter demo-service"

for srv in $SERVICES; do
  systemctl enable "$srv" || echo "  [WARN] Could not enable $srv"
  systemctl restart "$srv" || echo "  [WARN] Could not start $srv – check: journalctl -u $srv -n 20"
done

# ============================================================================
# Section 10 – Health verification
# ============================================================================
progress "Waiting for services to initialize"
sleep 10

progress "Verifying health and printing access URLs"
echo ""
echo "==> Service Health Verification:"
ALL_OK=true
for srv in $SERVICES; do
  STATUS=$(systemctl is-active "$srv" 2>/dev/null || echo "unknown")
  if [ "$STATUS" = "active" ]; then
    echo "  [ OK ] $srv"
  else
    echo "  [FAIL] $srv ($STATUS) – run: journalctl -u $srv -n 30 --no-pager"
    ALL_OK=false
  fi
done

echo ""

# ============================================================================
# Section 11 – Print access URLs
# ============================================================================
SERVER_IP=$(curl -sf --max-time 5 ifconfig.me || curl -sf --max-time 5 icanhazip.com || echo "<server-ip>")

cat << EOF
========================================
Vuln Observability Stack – Access URLs
========================================
Grafana:       http://${SERVER_IP}:3000  (admin/admin)
Prometheus:    http://${SERVER_IP}:9090
Alertmanager:  http://${SERVER_IP}:9093
Loki:          http://${SERVER_IP}:3100
Tempo:         http://${SERVER_IP}:3200
Demo Service:  http://${SERVER_IP}:8080
========================================
EOF

if [ "$ALL_OK" = "false" ]; then
  echo "[NOTE] Some services failed. Use the journalctl commands above to diagnose each one."
fi

echo ""
echo "==> Installation progress: 100% complete"

exit 0
