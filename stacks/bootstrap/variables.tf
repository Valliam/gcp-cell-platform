variable "org_id" {
  type        = string
  description = "GCP organization id."
}

variable "billing_account" {
  type        = string
  description = "Billing account id."
}

variable "bootstrap_project_id" {
  type        = string
  description = "Globally unique id for the bootstrap project."
}

variable "bootstrap_folder_id" {
  type        = string
  description = "Folder to place the bootstrap project in, in `folders/NNN` form."
}

variable "state_bucket" {
  type        = string
  description = "Globally unique name for the Terraform state bucket."
}

variable "state_location" {
  type        = string
  default     = "australia-southeast1"
  description = <<-EOT
    Location for state and its KMS key. Single-region and inside the residency
    envelope: Terraform state describes regulated infrastructure and should not
    be replicated outside it.
  EOT
}

variable "github_owner" {
  type        = string
  description = "GitHub org or user. Used in the WIF attribute condition that stops any other repository from authenticating."
}

variable "github_repository" {
  type        = string
  description = "owner/repo allowed to run plans."
}
