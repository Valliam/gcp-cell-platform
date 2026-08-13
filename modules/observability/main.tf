# Observability for one cell.
#
# Two principles shape this module:
#
#  1. Audit logs leave the cell. A sink writes them to a bucket in the security
#     project that the cell's own identities cannot touch, so an attacker who
#     owns the cell cannot erase the evidence.
#  2. Alerts are tied to declared objectives, not to arbitrary thresholds. The
#     replica-lag alert fires at half the cell's declared RPO; the burn-rate
#     alert fires when the error budget is being consumed faster than the
#     window allows. Both numbers come from the cell contract.

# --- Audit log export ---------------------------------------------------------

resource "google_logging_project_sink" "audit" {
  project = var.project_id
  name    = "${var.name}-audit-to-security"

  destination = "storage.googleapis.com/${var.audit_log_bucket}"

  filter = <<-EOT
    logName:"logs/cloudaudit.googleapis.com%2Factivity"
    OR logName:"logs/cloudaudit.googleapis.com%2Fsystem_event"
    OR logName:"logs/cloudaudit.googleapis.com%2Fdata_access"
  EOT

  # Creates a dedicated writer identity for this sink. The IAM grant on the
  # destination bucket is made in stacks/org, in the security project — the cell
  # can write, and cannot read back or delete.
  unique_writer_identity = true
}

# Application logs stay in the cell but with a retention that matches the
# venture's obligations rather than the 30-day default.
resource "google_logging_project_bucket_config" "app" {
  project        = var.project_id
  location       = var.region
  bucket_id      = "${var.name}-app"
  retention_days = var.app_log_retention_days
  description    = "Application logs for ${var.name}, retained in-region for residency"
}

# --- Notification -------------------------------------------------------------

resource "google_monitoring_notification_channel" "this" {
  for_each = var.notification_channels

  project      = var.project_id
  display_name = each.key
  type         = each.value.type
  labels       = each.value.labels
}

locals {
  channels = [for c in google_monitoring_notification_channel.this : c.id]

  # Alert before the objective is missed, not after. Half the RPO gives an
  # on-call the same number of minutes to react that the objective allows for
  # data loss.
  replica_lag_threshold_seconds = (var.rpo_minutes * 60) / 2
}

# --- Disaster recovery ---------------------------------------------------------

# The single most important alert in the cell. If replica lag exceeds this, the
# declared RPO is already unachievable and the DR posture is a fiction.
resource "google_monitoring_alert_policy" "replica_lag" {
  count = var.database_instance == null || var.standby_region == null ? 0 : 1

  project      = var.project_id
  display_name = "[${var.name}] Cross-region replica lag exceeds RPO budget"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "replica lag > ${local.replica_lag_threshold_seconds}s"

    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"cloudsql.googleapis.com/database/replication/replica_lag\"",
        "resource.type=\"cloudsql_database\"",
        "resource.label.\"database_id\"=\"${var.project_id}:${var.database_instance}-standby\"",
      ])

      comparison      = "COMPARISON_GT"
      threshold_value = local.replica_lag_threshold_seconds
      duration        = "300s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = local.channels

  documentation {
    subject   = "[${var.name}] DR objective at risk"
    content   = <<-EOT
      The cross-region replica in ${var.standby_region} is lagging by more than
      half the declared RPO of ${var.rpo_minutes} minutes.

      This does not mean an outage. It means that if the primary region were
      lost right now, data loss would exceed what this cell has committed to.

      Runbook: docs/runbooks/failover.md, section "Replica lag".
    EOT
    mime_type = "text/markdown"
  }
}

resource "google_monitoring_alert_policy" "database_disk" {
  count = var.database_instance == null ? 0 : 1

  project      = var.project_id
  display_name = "[${var.name}] Database disk utilisation high"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "disk > 85%"

    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"cloudsql.googleapis.com/database/disk/utilization\"",
        "resource.type=\"cloudsql_database\"",
        "resource.label.\"project_id\"=\"${var.project_id}\"",
      ])

      comparison      = "COMPARISON_GT"
      threshold_value = 0.85
      duration        = "600s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = local.channels

  documentation {
    content   = "Autoresize is enabled, so this is a cost signal as much as a capacity one. Check for runaway table growth before raising the limit."
    mime_type = "text/markdown"
  }
}

# --- Workload health ----------------------------------------------------------

resource "google_monitoring_alert_policy" "pod_restarts" {
  project      = var.project_id
  display_name = "[${var.name}] Container restart storm"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "restarts > 5 in 15m"

    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"kubernetes.io/container/restart_count\"",
        "resource.type=\"k8s_container\"",
      ])

      comparison      = "COMPARISON_GT"
      threshold_value = 5
      duration        = "0s"

      aggregations {
        alignment_period     = "900s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.container_name"]
      }
    }
  }

  notification_channels = local.channels
}

# --- Availability objective ----------------------------------------------------

resource "google_monitoring_uptime_check_config" "this" {
  count = var.uptime_check_host == null ? 0 : 1

  project      = var.project_id
  display_name = "${var.name}-https"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path         = "/healthz"
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.uptime_check_host
    }
  }

  # Probe from the regions the venture actually serves. Probing from everywhere
  # generates alerts about networks you do not sell to.
  selected_regions = var.uptime_check_regions
}

resource "google_monitoring_custom_service" "this" {
  count = var.uptime_check_host == null ? 0 : 1

  project      = var.project_id
  service_id   = var.name
  display_name = var.name
}

resource "google_monitoring_slo" "availability" {
  count = var.uptime_check_host == null ? 0 : 1

  project      = var.project_id
  service      = google_monitoring_custom_service.this[0].service_id
  slo_id       = "availability"
  display_name = "${var.name} availability"

  goal                = var.availability_goal
  rolling_period_days = 28

  request_based_sli {
    good_total_ratio {
      good_service_filter = join(" AND ", [
        "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\"",
        "resource.type=\"uptime_url\"",
        "metric.label.\"check_id\"=\"${google_monitoring_uptime_check_config.this[0].uptime_check_id}\"",
        "metric.label.\"checked_value\"=\"true\"",
      ])

      total_service_filter = join(" AND ", [
        "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\"",
        "resource.type=\"uptime_url\"",
        "metric.label.\"check_id\"=\"${google_monitoring_uptime_check_config.this[0].uptime_check_id}\"",
      ])
    }
  }
}

# Burn-rate alerting rather than threshold alerting: page when the error budget
# is being consumed fast enough to exhaust the 28-day window early, and stay
# quiet when a brief blip has already been absorbed by the budget.
resource "google_monitoring_alert_policy" "error_budget_burn" {
  count = var.uptime_check_host == null ? 0 : 1

  project      = var.project_id
  display_name = "[${var.name}] Error budget burning fast"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "1h burn rate > 14.4x"

    condition_threshold {
      # 14.4x over one hour consumes 2% of a 28-day budget in that hour: the
      # standard fast-burn page.
      filter          = "select_slo_burn_rate(\"${google_monitoring_slo.availability[0].id}\", \"3600s\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 14.4
      duration        = "0s"
    }
  }

  notification_channels = local.channels

  documentation {
    content   = "Fast burn: at this rate the 28-day error budget is gone within days. Runbook: docs/runbooks/incident-response.md"
    mime_type = "text/markdown"
  }
}

# --- Security signal -----------------------------------------------------------

# Break-glass access is legitimate, but it must never be quiet. This turns any
# use of the elevated binding into a log-based metric and pages on it.
resource "google_logging_metric" "breakglass_used" {
  project = var.project_id
  name    = "${var.name}-breakglass-used"

  filter = <<-EOT
    logName:"logs/cloudaudit.googleapis.com%2Factivity"
    protoPayload.authorizationInfo.permission:"container."
    protoPayload.authorizationInfo.granted=true
    protoPayload.authenticationInfo.principalEmail!~"gserviceaccount.com$"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_monitoring_alert_policy" "breakglass_used" {
  project      = var.project_id
  display_name = "[${var.name}] Human performed a privileged action"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "any privileged human action"

    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"logging.googleapis.com/user/${google_logging_metric.breakglass_used.name}\"",
        "resource.type=\"k8s_cluster\"",
      ])

      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_DELTA"
      }
    }
  }

  notification_channels = local.channels

  documentation {
    content   = "Not necessarily an incident — but every privileged human action in a prod cell should be attributable to a change ticket or an active incident."
    mime_type = "text/markdown"
  }
}
