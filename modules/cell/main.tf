# One cell.
#
# This module is the whole product: it takes a decoded cell contract and
# produces an isolated GCP project containing a VPC, a private GKE cluster, a
# highly-available PostgreSQL instance with a cross-region standby, its own
# encryption keys, its own log export, its own alerts and its own budget.
#
# Nothing here branches on region or venture. Everything that varies is an input
# from ventures/<venture>/cells/<cell>.yaml, which is why adding the fifth cell
# costs one YAML file and adding the fiftieth costs the same.

locals {
  # Cells are named <venture>-<cell>; the project id adds a prefix so it can be
  # globally unique. scripts/validate_cells.py enforces the 30-character limit
  # in CI, before a doomed apply discovers it.
  cell_name  = "${var.cell.venture}-${var.cell.cell}"
  project_id = "${var.project_prefix}-${local.cell_name}"

  is_prod     = var.cell.env == "prod"
  is_hardened = contains(["staging", "prod"], var.cell.env)

  has_standby = try(var.cell.dr.standby_region, null) != null
  use_cmek    = try(var.cell.security.cmek, false)

  labels = {
    venture     = var.cell.venture
    cell        = var.cell.cell
    env         = var.cell.env
    cost_centre = var.venture.billing.cost_centre
    residency   = lower(replace(var.cell.region, "-", "_"))
    managed_by  = "terraform"
  }

  # Every cell enables the same API surface. A cell that needs more declares it
  # in the contract rather than having someone click it on in the console, which
  # is how a project ends up with an API nobody can account for.
  services = [
    "artifactregistry.googleapis.com",
    "cloudkms.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "dns.googleapis.com",
    "gkehub.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "pubsub.googleapis.com",
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
    "anthosconfigmanagement.googleapis.com",
  ]
}

module "project" {
  source = "../project"

  project_id   = local.project_id
  display_name = "${var.venture.display_name} — ${var.cell.cell}"
  folder_id    = var.folder_id

  billing_account = var.billing_account
  labels          = local.labels
  services        = local.services

  # Only dev cells may be destroyed by a plan.
  deletion_policy = local.is_prod ? "PREVENT" : (var.cell.env == "dev" ? "DELETE" : "PREVENT")

  platform_group    = var.venture.owners.platform
  security_group    = var.venture.owners.security
  breakglass_group  = try(var.cell.security.breakglass_group, null)
  breakglass_expiry = var.breakglass_expiry
}

# --- Encryption ----------------------------------------------------------------
# One key ring per region. A cross-region replica cannot use the primary's key,
# so a cell with a standby gets two.

module "kms_primary" {
  source = "../kms"
  count  = local.use_cmek ? 1 : 0

  project_id     = module.project.project_id
  project_number = module.project.project_number
  name           = local.cell_name
  region         = var.cell.region

  protection_level = local.is_prod ? "HSM" : "SOFTWARE"
  labels           = local.labels

  depends_on = [module.project]
}

module "kms_standby" {
  source = "../kms"
  count  = local.use_cmek && local.has_standby ? 1 : 0

  project_id     = module.project.project_id
  project_number = module.project.project_number
  name           = "${local.cell_name}-standby"
  region         = var.cell.dr.standby_region

  protection_level = local.is_prod ? "HSM" : "SOFTWARE"
  labels           = local.labels

  depends_on = [module.project]
}

# --- Network --------------------------------------------------------------------

module "network" {
  source = "../network"

  project_id = module.project.project_id
  name       = local.cell_name
  region     = var.cell.region

  subnet_cidr   = var.cell.network.subnet_cidr
  pods_cidr     = var.cell.network.pods_cidr
  services_cidr = var.cell.network.services_cidr
  master_cidr   = var.cell.network.master_cidr

  # Flow logs are priced per GB ingested. Full sampling in dev buys nothing and
  # costs real money.
  flow_log_sampling = local.is_prod ? 0.5 : 0.1
  nat_ip_count      = local.is_prod ? 2 : 1

  depends_on = [module.project]
}

# --- Compute ---------------------------------------------------------------------

module "gke" {
  source = "../gke"

  project_id = module.project.project_id
  name       = local.cell_name
  region     = var.cell.region

  network_id          = module.network.network_id
  subnetwork_id       = module.network.subnetwork_id
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name
  master_cidr         = var.cell.network.master_cidr

  enable_private_endpoint    = var.cell.gke.private_endpoint
  master_authorized_networks = var.cell.gke.private_endpoint ? [] : var.dev_authorized_networks

  release_channel = var.cell.gke.release_channel
  node_pools      = var.cell.gke.node_pools

  node_service_account = module.project.node_service_account
  rbac_security_group  = var.rbac_security_group

  etcd_kms_key      = local.use_cmek ? module.kms_primary[0].keys["gke"] : null
  boot_disk_kms_key = local.use_cmek ? module.kms_primary[0].keys["gke"] : null

  deletion_protection = local.is_prod

  # Each cell syncs the shared baseline plus its own overlay. Namespaces,
  # ResourceQuota and default-deny NetworkPolicy arrive as reviewed commits.
  config_sync = {
    repo       = var.config_sync_repo
    branch     = var.config_sync_branch
    policy_dir = "platform/cells/${var.cell.venture}/${var.cell.cell}"
  }

  labels = local.labels
}

# --- Data ------------------------------------------------------------------------

module "database" {
  source = "../database"

  project_id     = module.project.project_id
  project_number = module.project.project_number
  name           = local.cell_name
  region         = var.cell.region
  standby_region = try(var.cell.dr.standby_region, null)

  database_version  = var.cell.database.version
  tier              = var.cell.database.tier
  availability_type = var.cell.database.availability
  disk_size_gb      = var.cell.database.disk_size_gb

  network_self_link = module.network.network_self_link

  kms_key                 = local.use_cmek ? module.kms_primary[0].keys["sql"] : null
  standby_kms_key         = local.use_cmek && local.has_standby ? module.kms_standby[0].keys["sql"] : null
  secrets_kms_key         = local.use_cmek ? module.kms_primary[0].keys["secrets"] : null
  standby_secrets_kms_key = local.use_cmek && local.has_standby ? module.kms_standby[0].keys["secrets"] : null

  # Backups stay in the primary region rather than defaulting to a multi-region
  # bucket that might sit outside the residency envelope.
  backup_location = var.cell.region

  transaction_log_retention_days = local.is_prod ? 7 : 1
  retained_backups               = local.is_prod ? 30 : 7
  deletion_protection            = local.is_prod

  rotation = local.is_hardened ? {
    period             = var.secret_rotation_period
    next_rotation_time = var.secret_next_rotation_time
  } : null

  labels = local.labels

  # Cloud SQL private IP requires the service networking peering to exist.
  # Without this the first apply of a cell fails roughly ten minutes in.
  depends_on = [module.network]
}

# --- Observability -----------------------------------------------------------------

module "observability" {
  source = "../observability"

  project_id = module.project.project_id
  name       = local.cell_name
  region     = var.cell.region

  audit_log_bucket       = var.audit_log_bucket
  app_log_retention_days = local.is_prod ? 400 : 30

  notification_channels = {
    for channel in var.cell.observability.notification_channels :
    channel => var.notification_channel_definitions[channel]
  }

  database_instance = module.database.instance_name
  standby_region    = try(var.cell.dr.standby_region, null)
  rpo_minutes       = var.cell.dr.rpo_minutes

  uptime_check_host = try(var.cell.observability.uptime_check_host, null)
  availability_goal = local.is_prod ? 0.999 : 0.99
}

module "budget" {
  source = "../budget"

  billing_account = var.billing_account
  project_number  = module.project.project_number
  name            = local.cell_name
  env             = var.cell.env

  monthly_amount   = var.cell.budget.monthly_aud
  currency         = "AUD"
  alert_thresholds = var.cell.budget.alert_thresholds

  notification_channel_ids = values(module.observability.notification_channel_ids)
}

# --- Cross-cell wiring ---------------------------------------------------------------
# The only thing a cell shares with anything outside itself: read access to the
# shared Artifact Registry. Images are built once and promoted by digest, so the
# grant is read-only and the registry lives in a project no cell can write to.

resource "google_artifact_registry_repository_iam_member" "node_pull" {
  project    = var.shared_registry_project
  location   = var.shared_registry_location
  repository = var.shared_registry_repository
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${module.project.node_service_account}"
}

# --- CI identity -----------------------------------------------------------------------
# GitHub Actions authenticates through Workload Identity Federation and
# impersonates this per-cell deploy account. There is no exported key anywhere
# in the system, and a compromised workflow in one repository cannot reach
# another cell.

resource "google_service_account" "deploy" {
  project      = module.project.project_id
  account_id   = "cell-deploy"
  display_name = "CI deploy identity for ${local.cell_name}"

  depends_on = [module.project]
}

resource "google_project_iam_member" "deploy" {
  for_each = toset([
    "roles/container.developer",
    "roles/artifactregistry.reader",
    "roles/logging.viewer",
  ])

  project = module.project.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.deploy.email}"
}

resource "google_service_account_iam_member" "deploy_wif" {
  service_account_id = google_service_account.deploy.name
  role               = "roles/iam.workloadIdentityUser"

  # Scoped to one repository. Without the attribute.repository suffix, any
  # GitHub repository in the world could mint tokens for this account.
  member = "principalSet://iam.googleapis.com/projects/${var.bootstrap_project_number}/locations/global/workloadIdentityPools/${var.wif_pool_id}/attribute.repository/${var.github_repository}"
}
