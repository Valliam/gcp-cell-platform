variable "project_id" {
  type        = string
  description = "Project that owns the VPC."
}

variable "name" {
  type        = string
  description = "VPC name; also the prefix for every resource in this module."
}

variable "region" {
  type        = string
  description = "Primary region. The VPC itself is global; the subnet and NAT are regional."
}

variable "subnet_cidr" {
  type        = string
  description = "Node subnet range."
}

variable "pods_cidr" {
  type        = string
  description = "Secondary range for pod IPs (VPC-native cluster)."
}

variable "services_cidr" {
  type        = string
  description = "Secondary range for Kubernetes service IPs."
}

variable "master_cidr" {
  type        = string
  description = "/28 for the GKE control plane's Google-managed VPC. Must not overlap any cell range."
}

variable "nat_ip_count" {
  type        = number
  default     = 2
  description = <<-EOT
    Number of static egress IPs. Each IP provides ~64k ports shared across all
    NAT-ing instances; two is the floor for a prod cell so that one address can
    be rotated without dropping connections.
  EOT
}

variable "flow_log_sampling" {
  type        = number
  default     = 0.5
  description = "VPC flow log sampling rate. 0.5 in prod, lower it in dev to cut log volume cost."

  validation {
    condition     = var.flow_log_sampling > 0 && var.flow_log_sampling <= 1
    error_message = "flow_log_sampling must be in (0, 1]."
  }
}
