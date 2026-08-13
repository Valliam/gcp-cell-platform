variable "billing_account" {
  type        = string
  description = "Billing account that owns the budget."
}

variable "project_number" {
  type        = string
  description = "Numeric id of the cell project the budget filters on."
}

variable "name" {
  type        = string
  description = "Cell name."
}

variable "env" {
  type        = string
  description = "Environment, shown in the budget display name."
}

variable "monthly_amount" {
  type        = number
  description = "Monthly budget in whole currency units."
}

variable "currency" {
  type        = string
  default     = "AUD"
  description = "Currency code. Must match the billing account's currency."
}

variable "alert_thresholds" {
  type        = list(number)
  default     = [0.5, 0.9, 1.0]
  description = "Fractions of the budget at which to alert on actual spend."
}

variable "notification_channel_ids" {
  type        = list(string)
  default     = []
  description = "Monitoring notification channels to notify. Reuses the cell's existing channels."
}
