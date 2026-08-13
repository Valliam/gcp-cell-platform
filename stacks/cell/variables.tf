variable "cell_file" {
  type        = string
  description = "Path to the cell contract, e.g. ../../ventures/acme/cells/prod-syd.yaml."
}

variable "state_bucket" {
  type        = string
  description = "GCS bucket holding all Terraform state, created by stacks/bootstrap."
}

variable "project_prefix" {
  type        = string
  default     = "cp"
  description = "Prefix for generated project ids. Must match PROJECT_ID_PREFIX in scripts/validate_cells.py."
}

variable "billing_account" {
  type        = string
  description = "Billing account id."
}

variable "github_repository" {
  type        = string
  description = "owner/repo permitted to deploy into cells via Workload Identity Federation."
}

variable "config_sync_repo" {
  type        = string
  description = "Repository Config Sync reads the Kubernetes baseline from."
}

variable "config_sync_branch" {
  type        = string
  default     = "main"
  description = "Branch Config Sync tracks."
}

variable "notification_channel_definitions" {
  type = map(object({
    type   = string
    labels = map(string)
  }))

  default = {
    platform-oncall = {
      type   = "email"
      labels = { email_address = "platform-oncall@example.com" }
    }
    platform-lowpri = {
      type   = "email"
      labels = { email_address = "platform-notifications@example.com" }
    }
  }

  description = <<-EOT
    Notification channels available to cells. Email is a placeholder for this
    sample; anything that actually pages should be a PagerDuty or Opsgenie
    channel, because email is not an alerting mechanism at 3am.
  EOT
}

variable "dev_authorized_networks" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))

  default = [
    { cidr_block = "203.0.113.0/24", display_name = "office-syd" },
  ]

  description = "Ranges allowed to reach a dev cell's public control plane."
}

variable "breakglass_expiry" {
  type        = string
  default     = "2000-01-01T00:00:00Z"
  description = "Moved forward by an incident commander to open the break-glass window; left in the past otherwise."
}

variable "secret_next_rotation_time" {
  type        = string
  default     = "2026-10-01T00:00:00Z"
  description = "First secret rotation instant."
}
