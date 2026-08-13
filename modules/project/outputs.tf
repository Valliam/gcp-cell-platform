output "project_id" {
  value       = google_project.this.project_id
  description = "The cell's project id."
}

output "project_number" {
  value       = google_project.this.number
  description = "Numeric project id, needed for service-agent principals and VPC-SC perimeter membership."
}

output "node_service_account" {
  value       = google_service_account.node.email
  description = "Least-privilege service account for GKE nodes."
}

output "services_ready" {
  value       = [for s in google_project_service.this : s.id]
  description = "Handle to depend on so resources are not created before their API is enabled."
}
