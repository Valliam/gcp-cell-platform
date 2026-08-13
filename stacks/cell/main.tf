# The cell root module. There is exactly one of these for the entire platform.
#
# Every cell is an instantiation of it, distinguished only by which contract it
# is pointed at and which state prefix it writes to:
#
#   make plan CELL=acme/prod-syd
#     -> terraform init -backend-config="prefix=cells/acme/prod-syd"
#        terraform plan -var cell_file=../../ventures/acme/cells/prod-syd.yaml
#
# Copying this directory per cell would be the obvious alternative and it is a
# trap: N copies drift, and a fix has to be applied N times. See docs/adr/0002.

locals {
  cell    = yamldecode(file(var.cell_file))
  venture = yamldecode(file("${dirname(dirname(var.cell_file))}/venture.yaml"))

  # Folder layout is <venture>/<env>, resolved from the org stack's outputs.
  # A cell cannot choose its own folder — that is what makes the org policy
  # boundary non-negotiable.
  folder_id = data.terraform_remote_state.org.outputs.env_folders["${local.cell.venture}/${local.cell.env}"]
}

# The org stack owns folders, the audit bucket and the shared registry. Reading
# it as remote state rather than duplicating the ids means a change there
# propagates on the next cell apply instead of silently diverging.
data "terraform_remote_state" "org" {
  backend = "gcs"

  config = {
    bucket = var.state_bucket
    prefix = "org"
  }
}

data "terraform_remote_state" "bootstrap" {
  backend = "gcs"

  config = {
    bucket = var.state_bucket
    prefix = "bootstrap"
  }
}

module "cell" {
  source = "../../modules/cell"

  cell    = local.cell
  venture = local.venture

  project_prefix  = var.project_prefix
  folder_id       = local.folder_id
  billing_account = var.billing_account

  audit_log_bucket = data.terraform_remote_state.org.outputs.audit_log_bucket

  shared_registry_project    = data.terraform_remote_state.org.outputs.registry_project_id
  shared_registry_location   = data.terraform_remote_state.org.outputs.registry_location
  shared_registry_repository = data.terraform_remote_state.org.outputs.registry_repository

  bootstrap_project_number = data.terraform_remote_state.bootstrap.outputs.project_number
  wif_pool_id              = data.terraform_remote_state.bootstrap.outputs.wif_pool_id
  github_repository        = var.github_repository

  rbac_security_group = var.rbac_security_group

  config_sync_repo   = var.config_sync_repo
  config_sync_branch = var.config_sync_branch

  notification_channel_definitions = var.notification_channel_definitions
  dev_authorized_networks          = var.dev_authorized_networks

  breakglass_expiry         = var.breakglass_expiry
  secret_next_rotation_time = var.secret_next_rotation_time
}
