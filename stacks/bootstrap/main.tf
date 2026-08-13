# Bootstrap: the one stack that cannot bootstrap itself.
#
# It creates the state bucket that every other stack stores state in, so its own
# first apply runs against local state and is then migrated:
#
#   terraform init && terraform apply          # local state
#   terraform init -backend-config=... -migrate-state
#
# After that it is an ordinary stack. Keeping it small is deliberate: it holds
# the credentials of last resort, so the fewer things in it, the fewer reasons
# anyone has to touch it.

resource "google_project" "bootstrap" {
  name       = "platform-bootstrap"
  project_id = var.bootstrap_project_id
  folder_id  = var.bootstrap_folder_id

  billing_account     = var.billing_account
  auto_create_network = false
  deletion_policy     = "PREVENT"

  labels = {
    managed_by = "terraform"
    tier       = "bootstrap"
  }
}

resource "google_project_service" "bootstrap" {
  for_each = toset([
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "storage.googleapis.com",
    "cloudkms.googleapis.com",
    "serviceusage.googleapis.com",
  ])

  project                    = google_project.bootstrap.project_id
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false
}

# --- Terraform state -----------------------------------------------------------

resource "google_kms_key_ring" "state" {
  project  = google_project.bootstrap.project_id
  name     = "tfstate"
  location = var.state_location

  depends_on = [google_project_service.bootstrap]
}

resource "google_kms_crypto_key" "state" {
  name            = "tfstate"
  key_ring        = google_kms_key_ring.state.id
  rotation_period = "7776000s"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key_iam_member" "state" {
  crypto_key_id = google_kms_crypto_key.state.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${google_project.bootstrap.number}@gs-project-accounts.iam.gserviceaccount.com"
}

resource "google_storage_bucket" "state" {
  project  = google_project.bootstrap.project_id
  name     = var.state_bucket
  location = var.state_location

  # State files contain resource ids, IP ranges and occasionally generated
  # secrets. Public access must be impossible, not merely unconfigured.
  public_access_prevention    = "enforced"
  uniform_bucket_level_access = true

  # Versioning is the difference between "someone corrupted state" and "someone
  # corrupted state and we restored it in two minutes".
  versioning {
    enabled = true
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.state.id
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 30
    }
    action {
      type = "Delete"
    }
  }

  # GCS provides native state locking, so there is no lock table to run or pay
  # for — a small but real advantage over the S3 + DynamoDB arrangement.

  depends_on = [google_kms_crypto_key_iam_member.state]
}

# --- Workload Identity Federation for GitHub Actions ----------------------------
# The point of this stack. Once it exists, no service account key is ever
# created, exported or stored anywhere in the platform.

resource "google_iam_workload_identity_pool" "github" {
  project                   = google_project.bootstrap.project_id
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"
  description               = "Federated identity for CI. No exported keys exist."

  depends_on = [google_project_service.bootstrap]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = google_project.bootstrap.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
    "attribute.actor"      = "assertion.actor"
  }

  # Without this condition, *any* GitHub repository on the internet can present
  # a valid token to this provider. The mapping alone does not restrict
  # anything; the condition does. This is the single most consequential line in
  # the bootstrap stack.
  attribute_condition = "assertion.repository_owner == '${var.github_owner}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# --- Terraform's own identity ----------------------------------------------------
# CI plans and applies as this account. It is granted at the org level because
# it creates projects and folders; that power is the reason the bootstrap
# project is separate, tightly scoped and rarely changed.

resource "google_service_account" "terraform" {
  project      = google_project.bootstrap.project_id
  account_id   = "terraform"
  display_name = "Terraform automation"

  depends_on = [google_project_service.bootstrap]
}

resource "google_organization_iam_member" "terraform" {
  for_each = toset([
    "roles/resourcemanager.folderAdmin",
    "roles/resourcemanager.projectCreator",
    "roles/orgpolicy.policyAdmin",
    "roles/accesscontextmanager.policyAdmin",
    "roles/billing.user",
    "roles/iam.serviceAccountAdmin",
  ])

  org_id = var.org_id
  role   = each.value
  member = "serviceAccount:${google_service_account.terraform.email}"
}

resource "google_storage_bucket_iam_member" "terraform_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.terraform.email}"
}

# Plan-only identity for pull requests. A PR from a fork must never be able to
# apply, and separating the identities is more robust than relying on workflow
# logic to enforce it.
resource "google_service_account" "terraform_plan" {
  project      = google_project.bootstrap.project_id
  account_id   = "terraform-plan"
  display_name = "Terraform plan (read-only)"

  depends_on = [google_project_service.bootstrap]
}

resource "google_organization_iam_member" "terraform_plan" {
  for_each = toset([
    "roles/viewer",
    "roles/iam.securityReviewer",
  ])

  org_id = var.org_id
  role   = each.value
  member = "serviceAccount:${google_service_account.terraform_plan.email}"
}

resource "google_storage_bucket_iam_member" "terraform_plan_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.terraform_plan.email}"
}

# Apply is restricted to the default branch. A branch push cannot mint an apply
# credential even if the workflow file on that branch says it should.
resource "google_service_account_iam_member" "terraform_wif" {
  service_account_id = google_service_account.terraform.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${google_project.bootstrap.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.github.workload_identity_pool_id}/attribute.ref/refs/heads/main"
}

resource "google_service_account_iam_member" "terraform_plan_wif" {
  service_account_id = google_service_account.terraform_plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${google_project.bootstrap.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.github.workload_identity_pool_id}/attribute.repository/${var.github_repository}"
}
