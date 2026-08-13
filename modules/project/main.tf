# The project is the cell's isolation boundary. Everything else in the cell is
# created inside it, and nothing outside the cell holds IAM on it except the
# venture's platform group and the CI deploy service account.

resource "google_project" "this" {
  name       = var.display_name
  project_id = var.project_id
  folder_id  = var.folder_id

  billing_account = var.billing_account
  labels          = var.labels

  # No default VPC. The default network comes with permissive firewall rules
  # (allow-internal, allow-ssh from 0.0.0.0/0) that have no place in a cell.
  auto_create_network = false

  # PREVENT makes `terraform destroy` fail rather than delete a live project.
  # Dev cells set DELETE so they can be torn down nightly.
  deletion_policy = var.deletion_policy
}

resource "google_project_service" "this" {
  for_each = toset(var.services)

  project = google_project.this.project_id
  service = each.value

  # Leave APIs enabled on destroy. Disabling an API can cascade into deleting
  # its resources, which turns a partial destroy into a data-loss event.
  disable_on_destroy         = false
  disable_dependent_services = false
}

# Least-privilege node identity. Using the default compute service account —
# which carries project Editor — is the single most common way a compromised
# pod becomes a compromised project.
resource "google_service_account" "node" {
  project      = google_project.this.project_id
  account_id   = "gke-node"
  display_name = "GKE node identity for ${var.project_id}"
  depends_on   = [google_project_service.this]
}

resource "google_project_iam_member" "node" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ])

  project = google_project.this.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.node.email}"
}

# Venture platform team gets operational access to the cell; security gets
# read-only plus the ability to inspect audit logs. Both are groups — never
# individual users — so that offboarding never requires a Terraform apply.
resource "google_project_iam_member" "platform" {
  project = google_project.this.project_id
  role    = "roles/container.developer"
  member  = var.platform_group
}

resource "google_project_iam_member" "security_view" {
  for_each = toset([
    "roles/viewer",
    "roles/logging.privateLogViewer",
    "roles/securitycenter.findingsViewer",
  ])

  project = google_project.this.project_id
  role    = each.value
  member  = var.security_group
}

# Break-glass: elevated access exists but is not granted in steady state. The
# binding is conditional and expires, so an incident commander who forgets to
# revoke it is still safe. `var.breakglass_expiry` is an explicit input rather
# than a computed timestamp so that a routine plan does not show perpetual drift.
resource "google_project_iam_member" "breakglass" {
  count = var.breakglass_group == null ? 0 : 1

  project = google_project.this.project_id
  role    = "roles/container.admin"
  member  = var.breakglass_group

  condition {
    title       = "breakglass-window"
    description = "Time-bound incident access; see docs/runbooks/incident-response.md"
    expression  = "request.time < timestamp(\"${var.breakglass_expiry}\")"
  }
}

# Every admin action in the cell is captured. The sink that ships these off the
# project lives in modules/observability so the cell cannot delete its own
# audit trail.
resource "google_project_iam_audit_config" "all" {
  project = google_project.this.project_id
  service = "allServices"

  audit_log_config {
    log_type = "ADMIN_READ"
  }
  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}
