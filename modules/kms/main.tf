# Customer-managed encryption keys for one region of a cell.
#
# KMS key rings are regional and a CMEK-encrypted resource must use a key in
# its own region. A cell with a Melbourne standby therefore instantiates this
# module twice — Sydney and Melbourne — which is also the reason a cross-region
# read replica cannot simply reuse the primary's key.
#
# Key rings cannot be deleted, ever. That is a GCP property, not an oversight:
# plan for the name to outlive the cell.

locals {
  key_names = ["gke", "sql", "storage", "secrets"]

  # Each Google-managed service agent must be able to use the key it encrypts
  # with. Getting this wrong produces a resource creation failure several
  # minutes into an apply, which is a miserable way to find out.
  key_agents = {
    gke = [
      "serviceAccount:service-${var.project_number}@container-engine-robot.iam.gserviceaccount.com",
      "serviceAccount:service-${var.project_number}@compute-system.iam.gserviceaccount.com",
    ]
    sql = [
      "serviceAccount:service-${var.project_number}@gcp-sa-cloud-sql.iam.gserviceaccount.com",
    ]
    storage = [
      "serviceAccount:service-${var.project_number}@gs-project-accounts.iam.gserviceaccount.com",
    ]
    secrets = [
      "serviceAccount:service-${var.project_number}@gcp-sa-secretmanager.iam.gserviceaccount.com",
    ]
  }

  grants = merge([
    for key, members in local.key_agents : {
      for member in members : "${key}/${member}" => { key = key, member = member }
    }
  ]...)
}

resource "google_kms_key_ring" "this" {
  project  = var.project_id
  name     = var.name
  location = var.region
}

resource "google_kms_crypto_key" "this" {
  for_each = toset(local.key_names)

  name     = each.value
  key_ring = google_kms_key_ring.this.id
  purpose  = "ENCRYPT_DECRYPT"

  # Automatic rotation. Existing ciphertext stays readable by the old version;
  # rotation only changes which version new writes use, so this is safe to run
  # unattended. Cloud SQL and GKE etcd pick up new versions transparently.
  rotation_period = var.rotation_period

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = var.protection_level
  }

  labels = var.labels

  lifecycle {
    # Destroying a key schedules its material for deletion and makes every
    # resource it encrypted permanently unreadable. Never let a plan do it
    # implicitly.
    prevent_destroy = true
  }
}

# Some service agents are created lazily, on first use of the service. Cloud SQL
# is the classic offender: granting its agent a key role before the agent exists
# fails with a confusing "member not found". Forcing creation first removes the
# race.
resource "google_project_service_identity" "sql" {
  provider = google-beta

  project = var.project_id
  service = "sqladmin.googleapis.com"
}

resource "google_project_service_identity" "secretmanager" {
  provider = google-beta

  project = var.project_id
  service = "secretmanager.googleapis.com"
}

resource "google_kms_crypto_key_iam_member" "agents" {
  for_each = local.grants

  crypto_key_id = google_kms_crypto_key.this[each.value.key].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = each.value.member

  depends_on = [
    google_project_service_identity.sql,
    google_project_service_identity.secretmanager,
  ]
}
