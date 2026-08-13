output "project_id" {
  value       = google_project.bootstrap.project_id
  description = "Bootstrap project id."
}

output "project_number" {
  value       = google_project.bootstrap.number
  description = "Numeric id, needed to construct WIF principal strings."
}

output "state_bucket" {
  value       = google_storage_bucket.state.name
  description = "Terraform state bucket."
}

output "wif_pool_id" {
  value       = google_iam_workload_identity_pool.github.workload_identity_pool_id
  description = "Workload Identity pool id."
}

output "wif_provider" {
  value       = google_iam_workload_identity_pool_provider.github.name
  description = "Full provider resource name; goes into the GitHub Actions auth step."
}

output "terraform_service_account" {
  value       = google_service_account.terraform.email
  description = "Identity used for applies from the default branch."
}

output "terraform_plan_service_account" {
  value       = google_service_account.terraform_plan.email
  description = "Read-only identity used for pull request plans."
}
