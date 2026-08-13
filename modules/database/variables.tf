variable "project_id" {
  type        = string
  description = "Project that owns the instances."
}

variable "project_number" {
  type        = string
  description = "Numeric project id, for service-agent principals and the Workload Identity subject."
}

variable "name" {
  type        = string
  description = "Instance name. Cloud SQL names are reserved for a week after deletion — do not reuse casually."
}

variable "region" {
  type        = string
  description = "Primary region."
}

variable "standby_region" {
  type        = string
  default     = null
  description = "Region for the asynchronous cross-region replica. Null disables cross-region DR (dev only)."
}

variable "database_version" {
  type        = string
  default     = "POSTGRES_16"
  description = "Cloud SQL engine version."
}

variable "tier" {
  type        = string
  description = "Machine tier for the primary."
}

variable "standby_tier" {
  type        = string
  default     = null
  description = "Optional smaller tier for the replica. Defaults to the primary tier; undersizing it means a slower RTO after promotion."
}

variable "availability_type" {
  type        = string
  default     = "REGIONAL"
  description = "REGIONAL adds a synchronous standby in a second zone; ZONAL does not."

  validation {
    condition     = contains(["REGIONAL", "ZONAL"], var.availability_type)
    error_message = "availability_type must be REGIONAL or ZONAL."
  }
}

variable "disk_size_gb" {
  type        = number
  default     = 20
  description = "Initial disk size; autoresize is enabled up to 4x this."
}

variable "network_self_link" {
  type        = string
  description = "VPC self link for private IP. Requires the PSA connection to exist first."
}

variable "kms_key" {
  type        = string
  default     = null
  description = "CMEK for the primary instance. Must be a key in var.region."
}

variable "standby_kms_key" {
  type        = string
  default     = null
  description = "CMEK for the replica. Must be a key in var.standby_region — keys are not usable across regions."
}

variable "secrets_kms_key" {
  type        = string
  default     = null
  description = "CMEK for the Secret Manager replica in var.region."
}

variable "standby_secrets_kms_key" {
  type        = string
  default     = null
  description = "CMEK for the Secret Manager replica in var.standby_region."
}

variable "backup_location" {
  type        = string
  description = "Backup storage location. Must stay inside the venture's residency envelope."
}

variable "transaction_log_retention_days" {
  type        = number
  default     = 7
  description = "How far back point-in-time recovery can rewind."

  validation {
    condition     = var.transaction_log_retention_days >= 1 && var.transaction_log_retention_days <= 35
    error_message = "transaction_log_retention_days must be between 1 and 35."
  }
}

variable "retained_backups" {
  type        = number
  default     = 30
  description = "Number of automated backups to keep."
}

variable "deletion_protection" {
  type        = bool
  default     = true
  description = "Sets both the Terraform-level and API-level deletion guards."
}

variable "database_name" {
  type        = string
  default     = "app"
  description = "Application database name."
}

variable "database_user" {
  type        = string
  default     = "app"
  description = "Application database user."
}

variable "workload_namespace" {
  type        = string
  default     = "app"
  description = "Kubernetes namespace whose service account may read the DB secret."
}

variable "workload_service_account" {
  type        = string
  default     = "app"
  description = "Kubernetes service account granted secret access via Workload Identity."
}

variable "rotation" {
  type = object({
    period             = string
    next_rotation_time = string
  })
  default     = null
  description = <<-EOT
    Secret rotation schedule. `next_rotation_time` is an explicit RFC3339
    instant rather than a computed one: deriving it from timestamp() makes every
    plan show a diff, and a plan that is never clean is a plan nobody reads.
  EOT
}

variable "labels" {
  type        = map(string)
  default     = {}
  description = "Labels applied to instances and secrets."
}
