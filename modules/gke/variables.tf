variable "project_id" {
  type        = string
  description = "Project that owns the cluster."
}

variable "name" {
  type        = string
  description = "Cluster name; also the fleet membership id."
}

variable "region" {
  type        = string
  description = "Region for a regional (three-zone control plane) cluster."
}

variable "network_id" {
  type        = string
  description = "VPC id from modules/network."
}

variable "subnetwork_id" {
  type        = string
  description = "Subnet id from modules/network."
}

variable "pods_range_name" {
  type        = string
  description = "Secondary range name for pods."
}

variable "services_range_name" {
  type        = string
  description = "Secondary range name for services."
}

variable "master_cidr" {
  type        = string
  description = "/28 for the Google-managed control plane VPC."
}

variable "enable_private_endpoint" {
  type        = bool
  default     = true
  description = "True removes the control plane's public endpoint entirely; access is via Connect Gateway."
}

variable "master_authorized_networks" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default     = []
  description = "Only meaningful when the endpoint is public (dev cells)."
}

variable "release_channel" {
  type        = string
  default     = "REGULAR"
  description = "RAPID, REGULAR or STABLE."

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.release_channel)
    error_message = "release_channel must be RAPID, REGULAR or STABLE."
  }
}

variable "node_pools" {
  type = list(object({
    name         = string
    machine_type = string
    min_nodes    = number
    max_nodes    = number
    disk_size_gb = optional(number, 100)
  }))
  description = "Node pools, straight from the cell contract."

  validation {
    condition     = length(var.node_pools) > 0
    error_message = "At least one node pool is required."
  }

  validation {
    condition     = alltrue([for p in var.node_pools : p.max_nodes > p.min_nodes])
    error_message = "Every node pool must be able to scale: max_nodes must exceed min_nodes."
  }
}

variable "node_service_account" {
  type        = string
  description = "Least-privilege node identity from modules/project."
}

variable "etcd_kms_key" {
  type        = string
  default     = null
  description = "CMEK for application-layer Secret encryption in etcd. Null disables it (dev only)."
}

variable "boot_disk_kms_key" {
  type        = string
  default     = null
  description = "CMEK for node boot disks. Must be a key in the cluster's own region."
}

variable "deletion_protection" {
  type        = bool
  default     = true
  description = "Blocks accidental cluster deletion via Terraform."
}

variable "rbac_security_group" {
  type        = string
  default     = null
  description = <<-EOT
    Google Group whose nested groups drive Kubernetes RBAC. GKE requires the
    name to be exactly `gke-security-groups@<domain>`; other groups are nested
    inside it. Null disables group-based RBAC.
  EOT

  validation {
    condition     = var.rbac_security_group == null || can(regex("^gke-security-groups@", var.rbac_security_group))
    error_message = "rbac_security_group must be named gke-security-groups@<domain> — GKE rejects any other name."
  }
}

variable "config_sync" {
  type = object({
    repo       = string
    branch     = string
    policy_dir = string
  })
  description = "Git source for the Kubernetes baseline delivered by Config Sync."
}

variable "labels" {
  type        = map(string)
  default     = {}
  description = "Labels applied to nodes."
}
