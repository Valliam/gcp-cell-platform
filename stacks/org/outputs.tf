output "env_folders" {
  value = {
    for key, folder in google_folder.env : key => folder.name
  }
  description = "Map of \"<venture>/<env>\" to folder id. stacks/cell reads this to place a cell."
}

output "venture_folders" {
  value       = { for key, folder in google_folder.venture : key => folder.name }
  description = "Per-venture folder ids, where the residency policy is attached."
}

output "audit_log_bucket" {
  value       = google_storage_bucket.audit.name
  description = "Audit log archive bucket."
}

output "security_project_id" {
  value       = google_project.security.project_id
  description = "Security project id."
}

output "registry_project_id" {
  value       = google_project.shared.project_id
  description = "Project holding the shared Artifact Registry."
}

output "registry_location" {
  value       = google_artifact_registry_repository.images.location
  description = "Artifact Registry location."
}

output "registry_repository" {
  value       = google_artifact_registry_repository.images.repository_id
  description = "Artifact Registry repository id."
}

output "registry_url" {
  value       = "${google_artifact_registry_repository.images.location}-docker.pkg.dev/${google_project.shared.project_id}/${google_artifact_registry_repository.images.repository_id}"
  description = "Base image reference. Cells pull from here by digest."
}

output "access_policy_name" {
  value       = google_access_context_manager_access_policy.org.name
  description = "Access Context Manager policy id."
}

output "prod_perimeter" {
  value       = google_access_context_manager_service_perimeter.prod.name
  description = "Prod VPC-SC perimeter resource name."
}
