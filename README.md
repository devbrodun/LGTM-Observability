# Vuln Observability

Production-grade observability and reliability platform — LGTM Stack, DORA Metrics & SLOs.

## Quick Start (One-Command Deployment)

The entire stack is strictly managed as Infrastructure as Code using Terraform. Follow these three steps to provision the full platform onto a fresh server.

### Prerequisites
* **Git** installed to clone the repository
* **Terraform** (>= 1.5.0) installed on your local machine
* **SSH Private Key** configured for root/sudo access to your target server

### 1. Clone the repository
```bash
git clone https://github.com/MichaelAyz/vuln-observability.git
cd vuln-observability
```

### 2. Configure Variables & Secrets
We must never commit live secrets or environment-specific values to git. Copy the HCL example to create your local variables file:
```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```
Open `terraform/terraform.tfvars` and edit it. 

Configure the following fields:
*   **Infrastructure Keys & Hosts:** SSH private key path, remote host IP (`vm_host`), and SSH user.
*   **Secrets:** Slack Incoming Webhook URL and GitHub Personal Access Token (`github_pat`).
*   **Dynamic Telemetry Domains:** The external URLs for your Grafana (`grafana_external_url`) and Prometheus (`prometheus_external_url`) consoles. Ensure these match your `vm_host` IP.
*   **Blackbox Probe Targets:** Specify the list of HTTP (`blackbox_http_targets`) and SSL (`blackbox_ssl_targets`) endpoints to monitor.

This file is git-ignored to prevent accidental commits.

### 3. Deploy
```bash
cd terraform
terraform init
terraform apply -auto-approve
```
That's it! Terraform will package the repository, automatically strip Windows CRLF line endings/UTF-8 BOMs, copy the package, and remotely provision the entire stack dynamically.


---

## System Architecture & Dataflow

Our observability platform leverages a unified, high-performance Ubuntu instance running a fully self-hosted, custom-instrumented LGTM (Loki, Grafana, Tempo, Prometheus) telemetry engine.

### Architecture Diagram (ASCII)

```
                            ┌───────────────────────────────────────┐
                            │          OBSERVABILITY STACK          │
                            │             ARCHITECTURE              │
                            └───────────────────┬───────────────────┘
                                                │
                                                ▼
 ┌──────────────────────┐            ┌────────────────────┐            ┌──────────────────────┐
 │ APPLICATION SERVICE  │            │ SYSTEM EXPORTERS   │            │ EXTERNAL PROBING     │
 │ (Demo Flask Service) │            │ (Node / GitHub)    │            │ (Blackbox Exporter)  │
 └──────────┬───────────┘            └──────────┬─────────┘            └──────────┬───────────┘
            │                                   │                                 │
            │ (OTLP Logs                        │ (Prometheus                     │ (Health
            │  & Traces)                        │  Scrapes)                       │  Checks)
            ▼                                   ▼                                 ▼
 ┌──────────────────────┐            ┌────────────────────┐            ┌──────────┴───────────┐
 │  OTEL COLLECTOR      │            │   PROMETHEUS DB    │◄───────────┤  BLACKBOX EXPORTER   │
 └──────┬────────┬──────┘            └──────────┬─────────┘            └──────────────────────┘
        │        │                              │
        │        │                              │ (Evaluate
        │        │                              │  Alert Rules)
        ▼        ▼                              ▼
 ┌──────┴───┐┌───┴──────┐            ┌──────────┴─────────┐            ┌──────────────────────┐
 │  TEMPO   ││   LOKI   │            │   ALERTMANAGER     ├───────────►│    SLACK CHANNEL     │
 │ (Traces) ││ (Logs)   │            └────────────────────┘            │   (#DevOps-Alerts)   │
 └──────┬───┘└───┬──────┘                                              └──────────────────────┘
        │        │
        │        │ (Correlate & Query Metrics, Logs, & Traces)
        ▼        ▼
 ┌────────────────────────────────────────────────────────────────────────────────────────────┐
 │                                        GRAFANA UI                                          │
 └────────────────────────────────────────────────────────────────────────────────────────────┘
```

### Architectural Design Breakdown

1. **Telemetry Ingestion Layer (OpenTelemetry & Exporters)**
   * **OpenTelemetry Collector**: Serves as a unified telemetry gateway. It receives application spans (traces) and structured logging context, routing them asynchronously to Loki and Tempo.
   * **Node Exporter**: Installed natively on the host to collect low-level OS metrics (CPU, Memory, Disk, Network).
   * **Blackbox Exporter**: Runs external, multi-region synthetic network tests targeting our endpoints to measure real user availability.
   * **GitHub Actions Exporter**: Periodically queries the GitHub API to dynamically capture pipeline delivery performance for DORA analysis.

2. **Storage and Correlation Layer (The LGTM Core)**
   * **Prometheus**: Operates on a robust, non-intrusive pull topology to store system metrics periodically.
   * **Loki**: Serves as our zero-indexing log aggregation engine, matching logs dynamically using trace context tags.
   * **Tempo**: High-cardinality distributed tracing storage backend that enables full transaction transaction mapping.

3. **Visualization & Alerting Layer**
   * **Grafana**: The single plane of glass. Grafana integrates all three telemetry pillars, enabling engineers to click on a CPU or latency spike, pull the correlated Loki logs, and click a log trace ID to instantly trace the transaction in Tempo.
   * **Alertmanager**: Evaluates active alerts from Prometheus, de-duplicates noise, handles inhibition rules, and delivers formatted alerts to Slack.

---

| Component | Role | Port |
|-----------|------|------|
| Prometheus | Metrics collection & storage | 9090 |
| Loki | Log aggregation | 3100 |
| Tempo | Distributed tracing | 3200 |
| Grafana | Unified observability UI | 3000 |
| Node Exporter | System metrics | 9100 |
| Blackbox Exporter | HTTP/SSL probing | 9115 |
| Alertmanager | Alert routing & Slack delivery | 9093 |
| OTel Collector | Traces + logs pipeline | 4317/4318 |
| Demo Service | OTel-instrumented Flask app | 5000 |
| GitHub Actions Exporter | DORA metrics source | 9999 |

## Configure Data Collection, Exporters & Retention Policies

All metrics, logs, and traces are collected using a standardized, production-grade telemetry pipeline.

### Telemetry Flow & Data Collection
1. **Metrics Collection:**
   * **Prometheus:** Acts as the primary metrics database. It scrapes the following targets:
     * **Node Exporter:** Scrapes system-level metrics (CPU, Memory, Disk, Network) at a **15-second interval**.
     * **Blackbox Exporter:** Probes public HTTPS endpoints and SSL expiry for `vuln-watch.hng14.com` and `staging.vuln-watch.hng14.com`.
     * **GitHub Actions Exporter:** Pulls workflow run statuses, durations, and CI/CD events to feed DORA metrics at a **60-second interval**.
     * **OTel Collector / Demo Service:** Scrapes application metrics from the OpenTelemetry instrumented Flask application.
2. **Logs Collection:**
   * **Loki:** Serves as the log aggregation database. Application and system logs are ingested via the OpenTelemetry Collector and forwarded directly to Loki.
3. **Traces Collection:**
   * **Tempo:** Serves as the distributed tracing backend. Traces emitted from the OTel-instrumented demo service are received by the OTel Collector and forwarded directly to Tempo.

### Data Retention Periods
To manage disk usage and comply with policy standards, retention is strictly enforced:
*   **Prometheus (Metrics):** **15 Days** (configured via `--storage.tsdb.retention.time=15d` in the systemd service unit).
*   **Loki (Logs):** **7 Days** (configured via `limits_config.retention_period: 168h` and `retention_enabled: true` in `loki-config.yml`).
*   **Tempo (Traces):** **2 Days** (configured via `block_retention: 48h` in `tempo-config.yml`).

### systemd Services Hardening
All 9 core components run as native systemd services on the production server. Each service is fully configured with an automatic restart policy (`Restart=always`, `RestartSec=5`) to ensure zero-downtime availability and instant recovery after server reboot or process failure:

| Service Name | Description | Port | Restart Policy | Status |
|---|---|---|---|---|
| `prometheus.service` | Prometheus Monitoring Server | `9090` | `always` (5s delay) | `active (running)` |
| `loki.service` | Loki Log Aggregation System | `3100` | `always` (5s delay) | `active (running)` |
| `tempo.service` | Tempo Distributed Tracing Backend | `3200` | `always` (5s delay) | `active (running)` |
| `node-exporter.service` | System Metrics Exporter | `9100` | `always` (5s delay) | `active (running)` |
| `blackbox-exporter.service` | Network/HTTP Probe Exporter | `9115` | `always` (5s delay) | `active (running)` |
| `alertmanager.service` | Alert Notification Manager | `9093` | `always` (5s delay) | `active (running)` |
| `otel-collector.service` | OpenTelemetry Pipeline Collector | `4327/4328`| `always` (5s delay) | `active (running)` |
| `demo-service.service` | OpenTelemetry Instrumented App | `8080` | `always` (5s delay) | `active (running)` |
| `github-actions-exporter.service`| GitHub Actions DORA Exporter | `9999` | `always` (5s delay) | `active (running)` |

## Error Budget & Application SLOs Policy

System and application reliability are managed through strict Service Level Objectives (SLOs) and Error Budgets:
1.  **Availability (Platform SLO):** 99.5% uptime (measured via Blackbox probes). Provides a monthly availability Error Budget of ~216 minutes.
2.  **Latency (Application SLO):** 95% of requests complete under 500ms (p95 threshold of `demo-service`).
3.  **Errors (Application SLO):** 5xx error rate is restricted to < 1.0% of requests.
4.  **Saturation (System SLO):** Memory utilization (Resident Set Size) must stay under 85% of total RAM.
5.  **Traffic (routing SLO):** Sustained 0-traffic drop (5m window) triggers alert to identify routing/ingress failures.

### Action Thresholds & Escalations:
*   **> 50% Budget Consumed:** Slow down non-critical feature work and trigger a reliability architecture review.
*   **100% Budget Consumed:** Feature freeze enacted. Mandatory Post-Incident Review (PIR) and reliability sprint required before shipping new features.


## Dashboard Guide

The stack provisions 5 zero-config Grafana Dashboards to trace root causes seamlessly.
1. **Node Exporter**: System-level baseline (CPU, Memory, Disk, Network). Check here for resource starvation.
2. **Blackbox Exporter**: External HTTP uptime and SSL certificate expiry countdowns. Check here for routing/DNS or certificate failures.
3. **DORA Metrics**: CI/CD velocity. Tracks Deployment Frequency (Elite/High/Medium/Low), Lead Time for Changes, Change Failure Rate, and MTTR.
4. **SLO & Error Budget**: Tracks the burn rate of your Error Budget. Features Fast (14.4x) and Slow (5x) burn alerts.
5. **Unified Observability (The Most Important Dashboard)**:
   - Begin by observing error rate or latency spikes.
   - Select a time window on the spike.
   - The correlated **Loki Logs Panel** automatically syncs to that exact window.
   - Click the `TraceID` derived field in any log line to seamlessly jump into **Tempo** and view the distributed trace timeline.

## How to Update the Stack

To deploy configuration changes (like new Prometheus alert rules or Grafana dashboards):
```bash
# 1. Pull the latest code
git pull origin main

# 2. Re-apply Terraform
cd terraform
terraform apply -auto-approve
```
Terraform will automatically sync the directory diff and reload the systemd services with zero downtime.

---

## How to Tear Down & Destroy (Clean Purge)

If you need to tear down the environment, decommissioning is fully automated and managed via Terraform. 

To clean up all observability configurations, databases, and systemd services from the target server, run:
```bash
cd terraform
terraform destroy -auto-approve
```

### What Happens on Destroy?
Terraform triggers a remote cleanup script on the target VM that safely purges the entire stack:
1. **Gracefully Stops and Disables Services:** Stops and disables all 10 custom systemd services (`grafana-server`, `prometheus`, `loki`, `tempo`, `node-exporter`, `blackbox-exporter`, `alertmanager`, `otel-collector`, `github-actions-exporter`, and `demo-service`).
2. **Removes Configuration Directories:** Deletes `/etc/prometheus`, `/etc/loki`, `/etc/tempo`, `/etc/alertmanager`, `/etc/otel-collector`, `/etc/blackbox-exporter`, and `/etc/github-actions-exporter`.
3. **Wipes Telemetry Storage (Databases):** Wipes database storage and data folders under `/var/lib/prometheus`, `/var/lib/loki`, `/var/lib/tempo`, and Grafana dashboards to guarantee a fresh slate.
4. **Cleans Up App & Installation Files:** Deletes the `/opt/demo-service` and `/home/<user>/vuln-observability` application folders, including all active deployment logs.

---

## Troubleshooting & State Migration

### Error: "Missing map element" (e.g., `self.triggers` lacks `vm_host` key)

If you are migrating an existing deployment that was provisioned using an older version of the Terraform code, you may receive a "Missing map element" error when running `terraform destroy` or when Terraform attempts to replace resources. This happens because the older state file lacks the new connection keys (`vm_host`, `vm_user`, `ssh_private_key_path`) inside the `self.triggers` map.

#### The Fix:
You can break the state conflict and deploy dynamically by removing the old resource from your local Terraform state. This will bypass the old destroy script execution, allowing a fresh apply to safely record the correct triggers for future runs:

1. **Remove the resource from your Terraform state:**
   ```bash
   terraform state rm null_resource.deploy_observability_stack
   ```
2. **Re-deploy the stack dynamically:**
   ```bash
   terraform apply -auto-approve
   ```

Now, the state is synced with the new dynamic parameters, and future `terraform apply` or `terraform destroy` runs will execute flawlessly!
