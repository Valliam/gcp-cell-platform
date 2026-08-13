output "project_id" {
  value       = module.project.project_id
  description = "The cell's project id."
}

output "project_number" {
  value       = module.project.project_number
  description = "Numeric project id. stacks/org consumes this to place the cell inside a VPC-SC perimeter."
}

output "cluster_name" {
  value       = module.gke.cluster_name
  description = "GKE cluster name."
}

output "fleet_membership" {
  value       = module.gke.membership_id
  description = "Fleet membership, used by Connect Gateway to reach the private control plane."
}

output "database_connection_name" {
  value       = module.database.connection_name
  description = "Cloud SQL connection name for the Auth Proxy."
}

output "database_replica" {
  value       = module.database.replica_name
  description = "Cross-region standby instance, or null when the cell has no DR."
}

output "nat_ips" {
  value       = module.network.nat_ips
  description = "Static egress addresses for partner allowlisting."
}

output "audit_sink_writer_identity" {
  value       = module.observability.audit_sink_writer_identity
  description = "Identity that stacks/org must grant write access on the audit bucket."
}

output "deploy_service_account" {
  value       = google_service_account.deploy.email
  description = "Account GitHub Actions impersonates to deploy into this cell."
}

output "dr" {
  value = {
    standby_region = try(var.cell.dr.standby_region, null)
    rpo_minutes    = var.cell.dr.rpo_minutes
    rto_minutes    = var.cell.dr.rto_minutes
    replica        = module.database.replica_name
  }
  description = "DR posture, surfaced so the failover runbook and drill script can read it from state."
}
