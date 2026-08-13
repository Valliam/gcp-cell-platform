variable "cell" {
  type = object({
    venture = string
    cell    = string
    env     = string
    region  = string

    dr = object({
      standby_region = optional(string)
      rpo_minutes    = number
      rto_minutes    = number
    })

    network = object({
      subnet_cidr   = string
      pods_cidr     = string
      services_cidr = string
      master_cidr   = string
    })

    gke = object({
      release_channel  = string
      private_endpoint = bool
      node_pools = list(object({
        name         = string
        machine_type = string
        min_nodes    = number
        max_nodes    = number
        disk_size_gb = optional(number, 100)
      }))
      quotas = map(string)
    })

    database = object({
      version      = string
      tier         = string
      availability = string
      disk_size_gb = number
    })

    security = object({
      cmek                  = bool
      vpc_service_perimeter = bool
      breakglass_group      = optional(string)
    })

    observability = object({
      uptime_check_host     = optional(string)
      notification_channels = list(string)
    })

    budget = object({
      monthly_aud      = number
      alert_thresholds = list(number)
    })
  })

  description = <<-EOT
    The decoded cell contract. stacks/cell reads
    ventures/<venture>/cells/<cell>.yaml and passes it here verbatim, so this
    type is the schema the YAML must satisfy — a malformed contract fails at
    plan time with a typed error rather than halfway through an apply.
  EOT

  validation {
    condition     = contains(["dev", "staging", "prod"], var.cell.env)
    error_message = "cell.env must be dev, staging or prod."
  }

  validation {
    condition     = try(var.cell.dr.standby_region, null) != var.cell.region
    error_message = "dr.standby_region must differ from region; a standby in the same region is not disaster recovery."
  }

  validation {
    condition     = var.cell.env != "prod" || try(var.cell.dr.standby_region, null) != null
    error_message = "prod cells must declare dr.standby_region."
  }

  validation {
    condition     = var.cell.env == "dev" || var.cell.security.cmek
    error_message = "CMEK is mandatory from staging up."
  }
}

variable "venture" {
  type = object({
    venture      = string
    display_name = string
    owners = object({
      platform = string
      security = string
    })
    billing = object({
      cost_centre = string
    })
  })
  description = "The decoded venture contract that owns this cell."
}

variable "project_prefix" {
  type        = string
  description = "Short prefix making project ids globally unique, e.g. \"cp\"."
}

variable "folder_id" {
  type        = string
  description = "Environment folder under the venture folder, in `folders/NNN` form."
}

variable "billing_account" {
  type        = string
  description = "Billing account for the project and its budget."
}

variable "audit_log_bucket" {
  type        = string
  description = "Bucket in the security project receiving this cell's audit logs."
}

variable "shared_registry_project" {
  type        = string
  description = "Project holding the shared Artifact Registry. Cells get read-only access."
}

variable "shared_registry_location" {
  type        = string
  description = "Artifact Registry location."
}

variable "shared_registry_repository" {
  type        = string
  description = "Artifact Registry repository name."
}

variable "bootstrap_project_number" {
  type        = string
  description = "Numeric id of the bootstrap project that owns the Workload Identity pool."
}

variable "wif_pool_id" {
  type        = string
  description = "Workload Identity pool id used by GitHub Actions."
}

variable "github_repository" {
  type        = string
  description = "owner/repo permitted to impersonate this cell's deploy account."
}

variable "rbac_security_group" {
  type        = string
  default     = null
  description = "Google Group driving Kubernetes RBAC; must be named gke-security-groups@<domain>."
}

variable "config_sync_repo" {
  type        = string
  description = "Git repository Config Sync pulls the Kubernetes baseline from."
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
  description = "Channel name to definition. Cells reference these by name in their contract."
}

variable "dev_authorized_networks" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default     = []
  description = "Office/VPN ranges allowed to reach a dev cell's public control plane."
}

variable "breakglass_expiry" {
  type        = string
  default     = "2000-01-01T00:00:00Z"
  description = "RFC3339 expiry for the break-glass IAM binding. Defaults to the past, i.e. inert."
}

variable "secret_rotation_period" {
  type        = string
  default     = "7776000s" # 90 days
  description = "How often Secret Manager publishes a rotation reminder."
}

variable "secret_next_rotation_time" {
  type        = string
  default     = "2026-10-01T00:00:00Z"
  description = "First rotation instant. Explicit rather than computed so plans stay clean."
}
