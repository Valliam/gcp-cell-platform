variable "project_id" {
  type        = string
  description = "Globally unique project id. Derived as <prefix>-<venture>-<cell> by stacks/cell."
}

variable "display_name" {
  type        = string
  description = "Human-readable project name shown in the console."
}

variable "folder_id" {
  type        = string
  description = "Folder to create the project under, in `folders/NNN` form. Determines which org policies apply."
}

variable "billing_account" {
  type        = string
  description = "Billing account id to attach."
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to the project; the basis of all cost attribution."
}

variable "services" {
  type        = list(string)
  description = "APIs to enable on the project."
}

variable "deletion_policy" {
  type        = string
  default     = "PREVENT"
  description = "PREVENT blocks `terraform destroy` on the project. Dev cells override to DELETE."

  validation {
    condition     = contains(["PREVENT", "DELETE", "ABANDON"], var.deletion_policy)
    error_message = "deletion_policy must be PREVENT, DELETE or ABANDON."
  }
}

variable "platform_group" {
  type        = string
  description = "Group principal (group:...) granted day-to-day operational access."
}

variable "security_group" {
  type        = string
  description = "Group principal granted read-only and audit access."
}

variable "breakglass_group" {
  type        = string
  default     = null
  description = "Optional group granted time-bound elevated access during incidents."
}

variable "breakglass_expiry" {
  type        = string
  default     = "2000-01-01T00:00:00Z"
  description = <<-EOT
    RFC3339 instant after which the break-glass binding stops granting access.
    Defaults to the past, so the binding is inert until an incident commander
    deliberately moves it forward. Passed in rather than computed so that a
    routine plan never shows drift.
  EOT
}
