# A budget per cell, not per venture.
#
# Cell-level budgets are what make cost attributable: when spend moves, you know
# which cell moved it without querying a billing export. The alert is wired to
# the same notification channels as reliability alerts, because a cell that has
# quietly tripled in cost is an incident too.

resource "google_billing_budget" "this" {
  billing_account = var.billing_account
  display_name    = "${var.name} (${var.env})"

  budget_filter {
    projects = ["projects/${var.project_number}"]

    # Exclude credits so the alert reflects what the venture is actually
    # charged, not a number flattered by committed-use discounts that expire.
    credit_types_treatment = "EXCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = var.currency
      units         = tostring(var.monthly_amount)
    }
  }

  dynamic "threshold_rules" {
    for_each = var.alert_thresholds
    content {
      threshold_percent = threshold_rules.value
      spend_basis       = "CURRENT_SPEND"
    }
  }

  # Forecast-based alerting catches a cell that is on track to blow the budget
  # before it actually has, which is the only kind of cost alert you can still
  # act on.
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = var.notification_channel_ids
    disable_default_iam_recipients   = true
  }
}
