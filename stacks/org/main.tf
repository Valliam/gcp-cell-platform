# Organization layer: the resource hierarchy, the guardrails hung on it, and the
# two shared projects every cell depends on.
#
# The folder tree is generated from ventures/*/venture.yaml, so onboarding a
# venture is a directory and a YAML file — the same factory idea as cells,
# applied one level up.

locals {
  venture_files = fileset("${path.module}/../../ventures", "*/venture.yaml")

  ventures = {
    for f in local.venture_files :
    dirname(f) => yamldecode(file("${path.module}/../../ventures/${f}"))
  }

  envs = ["dev", "staging", "prod"]

  env_folders = {
    for pair in setproduct(keys(local.ventures), local.envs) :
    "${pair[0]}/${pair[1]}" => { venture = pair[0], env = pair[1] }
  }
}

# --- Hierarchy ------------------------------------------------------------------

resource "google_folder" "bootstrap" {
  display_name        = "bootstrap"
  parent              = "organizations/${var.org_id}"
  deletion_protection = true
}

resource "google_folder" "shared" {
  display_name        = "shared"
  parent              = "organizations/${var.org_id}"
  deletion_protection = true
}

resource "google_folder" "security" {
  display_name        = "security"
  parent              = "organizations/${var.org_id}"
  deletion_protection = true
}

resource "google_folder" "ventures" {
  display_name        = "ventures"
  parent              = "organizations/${var.org_id}"
  deletion_protection = true
}

resource "google_folder" "venture" {
  for_each = local.ventures

  display_name        = each.key
  parent              = google_folder.ventures.name
  deletion_protection = true
}

# Environment folders are where cells live. Splitting by env at the folder level
# is what allows prod to carry stricter policy than dev without any per-cell
# configuration.
resource "google_folder" "env" {
  for_each = local.env_folders

  display_name        = each.value.env
  parent              = google_folder.venture[each.value.venture].name
  deletion_protection = true
}

# --- Org policy: applies to everything, including future cells -------------------

resource "google_org_policy_policy" "disable_sa_keys" {
  name   = "organizations/${var.org_id}/policies/iam.disableServiceAccountKeyCreation"
  parent = "organizations/${var.org_id}"

  # The technical control that makes "we use Workload Identity Federation" true
  # rather than aspirational: nobody can create the key they would otherwise be
  # tempted to paste into a CI secret.
  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

resource "google_org_policy_policy" "no_external_ips" {
  name   = "organizations/${var.org_id}/policies/compute.vmExternalIpAccess"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      deny_all = "TRUE"
    }
  }
}

resource "google_org_policy_policy" "require_shielded_vm" {
  name   = "organizations/${var.org_id}/policies/compute.requireShieldedVm"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

resource "google_org_policy_policy" "uniform_bucket_access" {
  name   = "organizations/${var.org_id}/policies/storage.uniformBucketLevelAccess"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

resource "google_org_policy_policy" "disable_serial_port" {
  name   = "organizations/${var.org_id}/policies/compute.disableSerialPortAccess"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

# --- Data residency, per venture ---------------------------------------------------
# The hard boundary. A cell in a region outside its venture's envelope is
# rejected by CI (scripts/validate_cells.py) and, if that were bypassed, by GCP
# itself at apply time. Two independent controls, because residency is the one
# commitment a venture cannot walk back.

resource "google_org_policy_policy" "residency" {
  for_each = local.ventures

  name   = "${google_folder.venture[each.key].name}/policies/gcp.resourceLocations"
  parent = google_folder.venture[each.key].name

  spec {
    inherit_from_parent = false

    rules {
      values {
        allowed_values = each.value.data_residency.allowed_locations
      }
    }
  }
}

# --- Security project: audit log archive ---------------------------------------------

resource "google_project" "security" {
  name       = "platform-security"
  project_id = var.security_project_id
  folder_id  = google_folder.security.name

  billing_account     = var.billing_account
  auto_create_network = false
  deletion_policy     = "PREVENT"

  labels = { managed_by = "terraform", tier = "security" }
}

resource "google_project_service" "security" {
  for_each = toset([
    "storage.googleapis.com",
    "logging.googleapis.com",
    "cloudkms.googleapis.com",
  ])

  project                    = google_project.security.project_id
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false
}

resource "google_storage_bucket" "audit" {
  project  = google_project.security.project_id
  name     = var.audit_log_bucket
  location = var.primary_region

  public_access_prevention    = "enforced"
  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  # A retention policy stops anyone — including an org admin, including the
  # identity that wrote them — from deleting audit logs before the period
  # elapses.
  #
  # `is_locked = true` makes the policy itself permanent and can never be undone
  # or shortened. That is exactly what makes it worth having, and exactly why it
  # is off by default in this sample: locking a bucket in a demo org is an
  # irreversible mistake.
  retention_policy {
    retention_period = var.audit_retention_days * 86400
    is_locked        = var.lock_audit_retention
  }

  lifecycle_rule {
    condition {
      age = var.audit_retention_days + 365
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.security]
}

# Every cell's log sink writes here with its own generated identity. objectCreator
# rather than objectAdmin: a cell can add log objects and can neither read nor
# delete them, so owning a cell does not mean owning its audit trail.
resource "google_storage_bucket_iam_member" "audit_writers" {
  for_each = toset(var.audit_sink_writer_identities)

  bucket = google_storage_bucket.audit.name
  role   = "roles/storage.objectCreator"
  member = each.value
}

# Org-level sink: catches admin activity above the cells, where the cell-level
# sinks cannot see.
resource "google_logging_organization_sink" "audit" {
  name             = "org-audit-archive"
  org_id           = var.org_id
  destination      = "storage.googleapis.com/${google_storage_bucket.audit.name}"
  include_children = true

  filter = "logName:\"logs/cloudaudit.googleapis.com%2Factivity\" OR logName:\"logs/cloudaudit.googleapis.com%2Fsystem_event\""
}

resource "google_storage_bucket_iam_member" "org_sink_writer" {
  bucket = google_storage_bucket.audit.name
  role   = "roles/storage.objectCreator"
  member = google_logging_organization_sink.audit.writer_identity
}

# --- Shared project: the container registry -------------------------------------------
# Images are built once here and promoted by digest into every cell. Cells hold
# read-only access and no cell can write to it, which is what keeps a compromised
# staging cell from publishing an image that prod will pull.

resource "google_project" "shared" {
  name       = "platform-shared"
  project_id = var.shared_project_id
  folder_id  = google_folder.shared.name

  billing_account     = var.billing_account
  auto_create_network = false
  deletion_policy     = "PREVENT"

  labels = { managed_by = "terraform", tier = "shared" }
}

resource "google_project_service" "shared" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "cloudkms.googleapis.com",
    "containeranalysis.googleapis.com",
  ])

  project                    = google_project.shared.project_id
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false
}

resource "google_artifact_registry_repository" "images" {
  project       = google_project.shared.project_id
  location      = var.primary_region
  repository_id = "images"
  format        = "DOCKER"
  description   = "Shared container images. Built once, promoted by digest."

  docker_config {
    # A tag that can be moved is not an artifact reference. Immutable tags mean
    # the digest a change was tested against is the digest that reaches prod.
    immutable_tags = true
  }

  # Cost optimisation that runs itself: untagged layers from CI churn are the
  # bulk of registry spend and none of its value.
  cleanup_policies {
    id     = "delete-untagged-after-30d"
    action = "DELETE"

    condition {
      tag_state  = "UNTAGGED"
      older_than = "2592000s"
    }
  }

  cleanup_policies {
    id     = "keep-recent-releases"
    action = "KEEP"

    most_recent_versions {
      keep_count = 50
    }
  }

  # Vulnerability scanning on push, results in Container Analysis.
  vulnerability_scanning_config {
    enablement_config = "INHERITED"
  }

  depends_on = [google_project_service.shared]
}

# --- VPC Service Controls -----------------------------------------------------------
# The perimeter that stops data leaving via a Google API even when IAM would
# allow it: an exfiltration attempt from a compromised cell to an attacker-owned
# bucket is denied at the service layer, not the network layer.

resource "google_access_context_manager_access_policy" "org" {
  parent = "organizations/${var.org_id}"
  title  = "platform"
}

# Zero-trust condition for administrative access: corporate device, from an
# allowed country, on a current OS. Failing any of these means the perimeter
# does not admit you, regardless of your IAM roles.
resource "google_access_context_manager_access_level" "trusted_admin" {
  parent = "accessPolicies/${google_access_context_manager_access_policy.org.name}"
  name   = "accessPolicies/${google_access_context_manager_access_policy.org.name}/accessLevels/trusted_admin"
  title  = "trusted_admin"

  basic {
    combining_function = "AND"

    conditions {
      regions = var.admin_access_regions

      device_policy {
        require_screen_lock = true
        require_corp_owned  = true
        os_constraints {
          os_type                    = "DESKTOP_MAC"
          minimum_version            = "14.0.0"
          require_verified_chrome_os = false
        }
      }
    }
  }
}

resource "google_access_context_manager_service_perimeter" "prod" {
  parent = "accessPolicies/${google_access_context_manager_access_policy.org.name}"
  name   = "accessPolicies/${google_access_context_manager_access_policy.org.name}/servicePerimeters/prod"
  title  = "prod"

  status {
    restricted_services = [
      "storage.googleapis.com",
      "sqladmin.googleapis.com",
      "container.googleapis.com",
      "cloudkms.googleapis.com",
      "secretmanager.googleapis.com",
      "logging.googleapis.com",
      "monitoring.googleapis.com",
      "artifactregistry.googleapis.com",
      "bigquery.googleapis.com",
    ]

    access_levels = [google_access_context_manager_access_level.trusted_admin.name]

    vpc_accessible_services {
      enable_restriction = true
      allowed_services   = ["RESTRICTED-SERVICES"]
    }
  }

  lifecycle {
    # Membership is managed by the separate _resource resources below.
    #
    # Ordering problem worth understanding: a cell's project number does not
    # exist until the cell has been applied, but the cell cannot be applied
    # cleanly into a perimeter that already restricts it. So enrolment is a
    # second phase — apply the cell, then add it to the perimeter. Declaring
    # `resources` inline here instead would make the two stacks fight, each
    # removing what the other added.
    ignore_changes = [status[0].resources]
  }
}

resource "google_access_context_manager_service_perimeter_resource" "prod_cells" {
  for_each = toset(var.perimeter_project_numbers)

  perimeter_name = google_access_context_manager_service_perimeter.prod.name
  resource       = "projects/${each.value}"
}

# --- Assured Workloads ------------------------------------------------------------------
# Contractual data residency on top of the org policy: Google commits to
# personnel and support access staying within the jurisdiction, not merely to
# resources being created there.
#
# Opt-in per venture via `data_residency.assured_workloads` in venture.yaml, and
# off for every venture in this repository — creating one requires an
# appropriate support level and it is not something to switch on in a sample.
# The org policy in `google_org_policy_policy.residency` above is the control
# that is always on. See docs/adr/0007.

resource "google_assured_workloads_workload" "venture" {
  for_each = {
    for name, v in local.ventures : name => v
    if try(v.data_residency.assured_workloads, false)
  }

  organization      = var.org_id
  location          = var.assured_workloads_location
  display_name      = "${each.key}-assured"
  billing_account   = "billingAccounts/${var.billing_account}"
  compliance_regime = var.assured_workloads_regime

  # Assured Workloads creates and owns its own folder; cells intended to be
  # covered are created inside it rather than under the venture folder above.
  # That is a materially different hierarchy, which is the main reason enabling
  # this is a migration rather than a flag flip.
  labels = {
    venture    = each.key
    managed_by = "terraform"
  }
}
