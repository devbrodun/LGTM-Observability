# ============================================================================
# main.tf — Deploys the vuln-observability stack onto the existing VM via SSH
# ============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }

  backend "local" {}
}

resource "null_resource" "deploy_observability_stack" {

  triggers = {
    install_hash            = filemd5("${path.root}/../systemd/install.sh")
    github_repository_hash  = var.github_repository
    github_pat_hash         = var.github_pat
    slack_webhook_url_hash  = var.slack_webhook_url
    slack_bot_name          = var.slack_bot_name
    alert_email_to_hash     = var.alert_email_to
    smtp_smarthost_hash     = var.smtp_smarthost
    smtp_from_hash          = var.smtp_from
    smtp_username_hash      = var.smtp_username
    smtp_password_hash      = var.smtp_password
    grafana_external_url    = var.grafana_external_url
    prometheus_external_url = var.prometheus_external_url
    blackbox_http_targets   = join(",", var.blackbox_http_targets)
    blackbox_ssl_targets    = join(",", var.blackbox_ssl_targets)
    vm_host                 = var.vm_host
    vm_user                 = var.vm_user
    ssh_private_key_path    = var.ssh_private_key_path
  }

  # ── Step 1: Package and scp the repo to the VM (runs on your Windows machine)
  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-Command"]
    command     = <<-PS
      $repoRoot = Resolve-Path "${path.root}\.."
      $tarDest  = "$env:TEMP\deploy.tar.gz"
      $excludeArgs = @(
        "--exclude=.git",
        "--exclude=terraform/.terraform",
        "--exclude=terraform/terraform.tfstate",
        "--exclude=terraform/terraform.tfstate.backup",
        "--exclude=terraform/tf-debug.log",
        "--exclude=terraform/*.log",
        "--exclude=terraform/*.tmp"
      )

      Write-Host "==> Creating archive from $repoRoot"
      & tar -czf $tarDest @excludeArgs -C $repoRoot .

      if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

      Write-Host "==> Uploading archive to ${var.vm_user}@${var.vm_host}"
      scp -i "${var.ssh_private_key_path}" -o StrictHostKeyChecking=no -o BatchMode=yes $tarDest "${var.vm_user}@${var.vm_host}:/home/${var.vm_user}/deploy.tar.gz"

      if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

      Remove-Item $tarDest -ErrorAction SilentlyContinue
      Write-Host "==> Upload complete."
    PS
  }

  # ── Step 2: Extract and run the install script on the remote VM
  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      host        = self.triggers.vm_host
      user        = self.triggers.vm_user
      private_key = file(self.triggers.ssh_private_key_path)
      timeout     = "10m"
    }

    inline = [
      "set -eu",
      "echo '==> DIAG START' && id && uname -a && env | sort && echo '==> which:' && which tar && which bash && which sudo && echo '==> home:' && ls -la /home/${var.vm_user}/ && echo '==> DIAG END'",
      "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
      "echo '==> Installing base tools (tar) on remote host...' && export DEBIAN_FRONTEND=noninteractive && sudo timeout 900 apt-get update -y && sudo timeout 900 apt-get install -y tar",
      "test -f /home/${var.vm_user}/deploy.tar.gz && ls -lh /home/${var.vm_user}/deploy.tar.gz",
      "rm -rf /home/${var.vm_user}/vuln-observability",
      "mkdir -p /home/${var.vm_user}/vuln-observability",
      "tar -tzf /home/${var.vm_user}/deploy.tar.gz | head -n 20",
      "tar -xzf /home/${var.vm_user}/deploy.tar.gz -C /home/${var.vm_user}/vuln-observability",
      "rm -f /home/${var.vm_user}/deploy.tar.gz",
      "find /home/${var.vm_user}/vuln-observability -type f \\( -name '*.sh' -o -name '*.service' -o -name '*.yml' -o -name '*.yaml' \\) -print0 | xargs -0 sed -i 's/\\r$//'",
      "find /home/${var.vm_user}/vuln-observability -type f -name '*.sh' -print0 | xargs -0 sed -i '1s/^\\xEF\\xBB\\xBF//'",
      "chmod +x /home/${var.vm_user}/vuln-observability/systemd/install.sh",
      "echo '==> Running stack installer (max 30 minutes)...' && cd /home/${var.vm_user}/vuln-observability && sudo -E env VM_HOST='${var.vm_host}' SLACK_WEBHOOK_URL='${var.slack_webhook_url}' SLACK_BOT_NAME='${var.slack_bot_name}' ALERT_EMAIL_TO='${var.alert_email_to}' SMTP_SMARTHOST='${var.smtp_smarthost}' SMTP_FROM='${var.smtp_from}' SMTP_USERNAME='${var.smtp_username}' SMTP_PASSWORD='${var.smtp_password}' GITHUB_PAT='${var.github_pat}' GITHUB_REPOSITORY='${var.github_repository}' GRAFANA_EXTERNAL_URL='${var.grafana_external_url}' PROMETHEUS_EXTERNAL_URL='${var.prometheus_external_url}' ALERTMANAGER_EXTERNAL_URL='http://${var.vm_host}:9093' BLACKBOX_HTTP_TARGETS='${join(",", var.blackbox_http_targets)}' BLACKBOX_SSL_TARGETS='${join(",", var.blackbox_ssl_targets)}' timeout 1800 bash -euxo pipefail systemd/install.sh 2>&1 | tee /home/${var.vm_user}/install.log"
    ]
  }

  # Step 3: Cleanup on destroy — stop and remove observability stack from VM
  provisioner "remote-exec" {
    when = destroy

    connection {
      type        = "ssh"
      host        = self.triggers.vm_host
      user        = self.triggers.vm_user
      private_key = file(self.triggers.ssh_private_key_path)
      timeout     = "10m"
    }

    inline = [
      "set -eu",
      "echo '==> Destroy cleanup starting on remote host...'",
      "SERVICES='grafana-server prometheus loki tempo node-exporter blackbox-exporter alertmanager otel-collector github-actions-exporter demo-service'",
      "for s in $SERVICES; do sudo systemctl stop \"$s\" 2>/dev/null || true; done",
      "for s in $SERVICES; do sudo systemctl disable \"$s\" 2>/dev/null || true; done",
      "for f in prometheus loki tempo node-exporter blackbox-exporter alertmanager otel-collector github-actions-exporter demo-service; do sudo rm -f \"/etc/systemd/system/$${f}.service\"; done",
      "sudo systemctl daemon-reload",
      "sudo rm -rf /etc/prometheus /etc/loki /etc/tempo /etc/alertmanager /etc/otel-collector /etc/blackbox-exporter /etc/github-actions-exporter",
      "sudo rm -rf /var/lib/prometheus /var/lib/loki /var/lib/tempo /var/lib/alertmanager /var/lib/grafana/dashboards",
      "sudo rm -rf /opt/demo-service \"$HOME/vuln-observability\" \"$HOME/install.log\" \"$HOME/deploy.tar.gz\"",
      "sudo systemctl stop grafana-server 2>/dev/null || true",
      "sudo systemctl disable grafana-server 2>/dev/null || true",
      "echo '==> Destroy cleanup complete.'"
    ]
  }
}
