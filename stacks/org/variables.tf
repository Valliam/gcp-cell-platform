variable "org_id" {
  type        = string
  description = "GCP organization id."
}

variable "billing_account" {
  type        = string
  description = "Billing account id."
}

variable "primary_region" {
  type        = string
  default     = "australia-southeast1"
  description = "Region for the audit bucket and the shared registry."
}

variable "security_project_id" {
  type        = string
  description = "Globally unique id for the security project."
}

variable "shared_project_id" {
  type        = string
  description = "Globally unique id for the shared services project."
}

variable "audit_log_bucket" {
  type        = string
  description = "Globally unique name for the audit log archive bucket."
}

variable "audit_retention_days" {
  type        = number
  default     = 2555 # 7 years
  description = "Minimum retention enforced on audit logs."
}

variable "lock_audit_retention" {
  type        = bool
  default     = false
  description = <<-EOT
    Locks the retention policy permanently. Real regulated deployments set this
    true. It is irreversible — a locked bucket cannot have its retention
    shortened or removed by anyone, ever — so it defaults to false here.
  EOT
}

variable "audit_sink_writer_identities" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Per-cell log sink writer identities to grant objectCreator on the audit
    bucket. Populated from cell outputs after each cell is applied; the drift
    job flags cells whose sink is not yet granted.
  EOT
}

variable "perimeter_project_numbers" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Project numbers enrolled in the prod VPC-SC perimeter. Populated after the
    corresponding cells exist — see the ordering note in main.tf.
  EOT
}

variable "assured_workloads_location" {
  type        = string
  default     = "australia-southeast1"
  description = "Location for an Assured Workloads environment, when a venture opts in."
}

variable "assured_workloads_regime" {
  type        = string
  default     = "AU_REGIONS_AND_US_SUPPORT"
  description = <<-EOT
    Compliance regime for Assured Workloads. This is the Australian regions
    regime; the exact enum is provider-version specific, so it is a variable
    rather than a literal — confirm it against the provider you pin before
    enabling a venture.
  EOT
}

variable "admin_access_regions" {
  type        = list(string)
  default     = ["AU", "NZ"]
  description = "ISO 3166-1 alpha-2 country codes administrators may connect from."
}
