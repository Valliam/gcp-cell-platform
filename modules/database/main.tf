# The cell's PostgreSQL instance and its cross-region standby.
#
# DR topology:
#   REGIONAL availability  -> synchronous standby in a second zone of the
#                             primary region. Automatic failover, RPO 0, and it
#                             covers the common case (zone loss).
#   cross-region replica   -> asynchronous replica in the standby region. Covers
#                             regional loss. Non-zero RPO, bounded by replica
#                             lag, which is why lag is alerted on at rpo/2.
#
# Promotion is deliberately manual: an automatic cross-region promotion on a
# transient network partition is how you get two writers. See
# docs/runbooks/failover.md.

resource "google_sql_database_instance" "primary" {
  project = var.project_id
  name    = var.name
  region  = var.region

  database_version = var.database_version

  # Terraform-level guard. `settings.deletion_protection_enabled` below is the
  # API-level one; both exist and you want both, because they block different
  # paths to the same accident.
  deletion_protection = var.deletion_protection

  encryption_key_name = var.kms_key

  settings {
    tier = var.tier

    # REGIONAL provisions the synchronous standby.
    availability_type = var.availability_type
    edition           = "ENTERPRISE"

    disk_type             = "PD_SSD"
    disk_size             = var.disk_size_gb
    disk_autoresize       = true
    disk_autoresize_limit = var.disk_size_gb * 4

    deletion_protection_enabled = var.deletion_protection

    backup_configuration {
      enabled = true

      # 16:00 UTC is 02:00 AEST — after the nightly batch window, before the
      # morning traffic ramp.
      start_time = "16:00"

      # Point-in-time recovery. This is what turns "we have last night's backup"
      # into "we can rewind to 60 seconds before the bad migration".
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = var.transaction_log_retention_days

      backup_retention_settings {
        retained_backups = var.retained_backups
        retention_unit   = "COUNT"
      }

      # Backups are pinned to the residency envelope. The default is a
      # multi-region location that may sit outside it — a quiet way to breach
      # data residency with a setting nobody reads.
      location = var.backup_location
    }

    ip_configuration {
      # No public IP, ever. Reachable only from the cell's VPC.
      ipv4_enabled                                  = false
      private_network                               = var.network_self_link
      enable_private_path_for_google_cloud_services = true
      ssl_mode                                      = "ENCRYPTED_ONLY"
    }

    database_flags {
      name  = "cloudsql.enable_pgaudit"
      value = "on"
    }

    database_flags {
      name  = "log_min_duration_statement"
      value = "1000"
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = true
      record_client_address   = false # client IPs are personal data under some regimes
    }

    maintenance_window {
      day          = 7  # Sunday
      hour         = 16 # 02:00 Monday AEST
      update_track = "stable"
    }

    user_labels = var.labels
  }
}

# --- Cross-region standby -----------------------------------------------------

resource "google_sql_database_instance" "replica" {
  count = var.standby_region == null ? 0 : 1

  project = var.project_id
  name    = "${var.name}-standby"
  region  = var.standby_region

  database_version     = var.database_version
  master_instance_name = google_sql_database_instance.primary.name

  # A CMEK-encrypted replica needs a key in *its own* region — key rings are
  # regional and cannot be referenced across regions. This is the single most
  # common reason a cross-region replica fails to create.
  encryption_key_name = var.standby_kms_key

  deletion_protection = var.deletion_protection

  replica_configuration {
    # Never auto-promote. Promotion is a human decision made against the
    # runbook, because promoting on a partition gives you a split brain.
    failover_target = false
  }

  settings {
    tier    = var.standby_tier == null ? var.tier : var.standby_tier
    edition = "ENTERPRISE"

    # The replica is zonal: it is insurance against losing the primary region,
    # not a second production database. Making it REGIONAL doubles standby cost
    # for redundancy you only need after you have already promoted.
    availability_type = "ZONAL"

    disk_type       = "PD_SSD"
    disk_size       = var.disk_size_gb
    disk_autoresize = true

    deletion_protection_enabled = var.deletion_protection

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_self_link
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    insights_config {
      query_insights_enabled = true
    }

    user_labels = var.labels
  }
}

# --- Application database and credentials -------------------------------------

resource "google_sql_database" "app" {
  project  = var.project_id
  instance = google_sql_database_instance.primary.name
  name     = var.database_name
}

resource "random_password" "app" {
  length  = 32
  special = true

  # Excluding characters that break naive connection-string parsers. Learned
  # the hard way; leaving it undocumented is how it gets removed again.
  override_special = "!#$%*()-_=+[]{}<>:?"
}

resource "google_sql_user" "app" {
  project  = var.project_id
  instance = google_sql_database_instance.primary.name
  name     = var.database_user
  password = random_password.app.result

  lifecycle {
    # After the first rotation the live password no longer matches state.
    # Without this, every plan wants to reset it back to the original.
    ignore_changes = [password]
  }
}

resource "google_secret_manager_secret" "db_password" {
  project   = var.project_id
  secret_id = "${var.name}-db-password"

  # user_managed, not automatic. Automatic replication distributes the secret
  # globally, which silently violates a data-residency commitment. Pinning
  # replicas keeps the material inside the venture's declared envelope.
  replication {
    user_managed {
      replicas {
        location = var.region
        dynamic "customer_managed_encryption" {
          for_each = var.kms_key == null ? [] : [1]
          content {
            kms_key_name = var.secrets_kms_key
          }
        }
      }

      dynamic "replicas" {
        for_each = var.standby_region == null ? [] : [1]
        content {
          location = var.standby_region
          dynamic "customer_managed_encryption" {
            for_each = var.standby_secrets_kms_key == null ? [] : [1]
            content {
              kms_key_name = var.standby_secrets_kms_key
            }
          }
        }
      }
    }
  }

  # Secret Manager publishes a rotation reminder to this topic on schedule; the
  # rotator workload subscribes, mints a new password, updates the SQL user and
  # adds a new secret version. Secret Manager does not rotate anything itself —
  # a detail that surprises people who enable this and assume they are done.
  dynamic "rotation" {
    for_each = var.rotation == null ? [] : [var.rotation]
    content {
      rotation_period    = rotation.value.period
      next_rotation_time = rotation.value.next_rotation_time
    }
  }

  dynamic "topics" {
    for_each = var.rotation == null ? [] : [1]
    content {
      name = google_pubsub_topic.rotation[0].id
    }
  }

  labels = var.labels
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.app.result

  lifecycle {
    # The rotator adds versions out of band. Terraform owns version one and
    # then gets out of the way.
    ignore_changes = [secret_data]
  }
}

resource "google_pubsub_topic" "rotation" {
  count = var.rotation == null ? 0 : 1

  project = var.project_id
  name    = "${var.name}-secret-rotation"
  labels  = var.labels

  # The message names a secret that is due for rotation. That is a hint worth
  # protecting with the same key as the secret itself.
  kms_key_name = var.secrets_kms_key
}

# The Secret Manager service agent must be able to publish to the topic, or
# secret creation itself fails with a permission error on the topic.
resource "google_pubsub_topic_iam_member" "rotation_publisher" {
  count = var.rotation == null ? 0 : 1

  project = var.project_id
  topic   = google_pubsub_topic.rotation[0].name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${var.project_number}@gcp-sa-secretmanager.iam.gserviceaccount.com"
}

# Application pods read this secret through Workload Identity — no key files,
# no secret mounted from CI.
resource "google_secret_manager_secret_iam_member" "app_reader" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.db_password.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "principal://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/${var.workload_namespace}/sa/${var.workload_service_account}"
}
