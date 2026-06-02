variable "vm_host" {
  type        = string
  description = "IP or hostname of the monitoring VM"
}

variable "vm_user" {
  type        = string
  description = "SSH user on the monitoring VM"
}

variable "ssh_private_key_path" {
  type        = string
  description = "Path to the SSH private key for VM access"
  # No default — this must be supplied explicitly (never commit a key path)
}

variable "grafana_admin_password" {
  type        = string
  description = "Grafana admin password"
  sensitive   = true
  default     = "admin"
}

variable "slack_webhook_url" {
  type        = string
  description = "Slack Incoming Webhook URL for DevOps-Alerts"
  sensitive   = true
}

variable "slack_bot_name" {
  type        = string
  description = "Display name for Slack alerts bot in Alertmanager notifications"
}

variable "alert_email_to" {
  type        = string
  description = "Comma-separated email recipients for Alertmanager notifications"
}

variable "smtp_smarthost" {
  type        = string
  description = "SMTP host and port for Alertmanager, e.g. smtp.gmail.com:587"
}

variable "smtp_from" {
  type        = string
  description = "Sender email address for Alertmanager notifications"
}

variable "smtp_username" {
  type        = string
  description = "SMTP username for Alertmanager authentication"
  sensitive   = true
}

variable "smtp_password" {
  type        = string
  description = "SMTP password or app password for Alertmanager authentication"
  sensitive   = true
}

variable "github_pat" {
  type        = string
  description = "GitHub Personal Access Token with repo and workflow scopes"
  sensitive   = true
}

variable "github_repository" {
  type        = string
  description = "GitHub repository to watch for DORA metrics in org/repo format"
}

variable "aws_region" {
  type        = string
  description = "AWS region where the monitoring VM lives"
  default     = "eu-west-2"
}

variable "grafana_external_url" {
  type        = string
  description = "Externally reachable Grafana base URL, e.g. http://example.com:3000"
}

variable "prometheus_external_url" {
  type        = string
  description = "Externally reachable Prometheus base URL, e.g. http://example.com:9090"
}

variable "blackbox_http_targets" {
  type        = list(string)
  description = "HTTP/HTTPS URLs to probe with blackbox-http module"
}

variable "blackbox_ssl_targets" {
  type        = list(string)
  description = "host:port targets to probe with blackbox-ssl tcp_connect module"
}
