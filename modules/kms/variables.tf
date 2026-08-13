variable "project_id" {
  type        = string
  description = "Project that owns the key ring."
}

variable "project_number" {
  type        = string
  description = "Numeric project id, used to construct Google service-agent principals."
}

variable "name" {
  type        = string
  description = "Key ring name. Key rings are permanent — choose a name that outlives the cell."
}

variable "region" {
  type        = string
  description = "Key ring location. Must match the region of the resources it encrypts."
}

variable "rotation_period" {
  type        = string
  default     = "7776000s" # 90 days
  description = "Automatic key rotation period."
}

variable "protection_level" {
  type        = string
  default     = "SOFTWARE"
  description = "SOFTWARE or HSM. HSM roughly doubles key cost; prod-with-compliance uses HSM."

  validation {
    condition     = contains(["SOFTWARE", "HSM"], var.protection_level)
    error_message = "protection_level must be SOFTWARE or HSM."
  }
}

variable "labels" {
  type        = map(string)
  default     = {}
  description = "Labels applied to each key."
}
