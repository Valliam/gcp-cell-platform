variable "project_id" {
  type        = string
  description = "Cell project."
}

variable "name" {
  type        = string
  description = "Cell name, used as a prefix and in alert titles."
}

variable "region" {
  type        = string
  description = "Region for the in-cell log bucket. Keeps logs inside the residency envelope."
}

variable "audit_log_bucket" {
  type        = string
  description = "GCS bucket in the security project that receives this cell's audit logs."
}

variable "app_log_retention_days" {
  type        = number
  default     = 30
  description = "Retention for application logs. Raise for regulated ventures; log storage is a real cost line."
}

variable "notification_channels" {
  type = map(object({
    type   = string
    labels = map(string)
  }))
  description = <<-EOT
    Notification channels keyed by display name, e.g.
      platform-oncall = { type = "pagerduty", labels = { service_key = "..." } }
    Email is fine for low priority; anything that pages should not be email.
  EOT
}

variable "database_instance" {
  type        = string
  default     = null
  description = "Primary Cloud SQL instance name. Null skips database alerts."
}

variable "standby_region" {
  type        = string
  default     = null
  description = "Standby region. Null skips the replica-lag alert, since there is no replica."
}

variable "rpo_minutes" {
  type        = number
  description = "Declared RPO from the cell contract. The replica-lag alert fires at half this."
}

variable "uptime_check_host" {
  type        = string
  default     = null
  description = "Public hostname to probe. Null skips the uptime check, SLO and burn-rate alert."
}

variable "uptime_check_regions" {
  type        = list(string)
  default     = ["ASIA_PACIFIC"]
  description = "Probe locations. Default matches an APAC-serving venture."
}

variable "availability_goal" {
  type        = number
  default     = 0.999
  description = "SLO target over a rolling 28 days."

  validation {
    condition     = var.availability_goal > 0 && var.availability_goal < 1
    error_message = "availability_goal must be a fraction between 0 and 1, e.g. 0.999."
  }
}
