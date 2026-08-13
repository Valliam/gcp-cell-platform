output "project_id" {
  value       = module.cell.project_id
  description = "The cell's project id."
}

output "project_number" {
  value       = module.cell.project_number
  description = "Numeric project id; stacks/org reads this to place the cell in a VPC-SC perimeter."
}

output "cluster_name" {
  value       = module.cell.cluster_name
  description = "GKE cluster name."
}

output "deploy_service_account" {
  value       = module.cell.deploy_service_account
  description = "Service account CI impersonates for this cell."
}

output "nat_ips" {
  value       = module.cell.nat_ips
  description = "Static egress IPs."
}

output "dr" {
  value       = module.cell.dr
  description = "DR posture, read by scripts/dr_drill.sh."
}

output "audit_sink_writer_identity" {
  value       = module.cell.audit_sink_writer_identity
  description = "Grant this objectCreator on the audit bucket in stacks/org."
}
