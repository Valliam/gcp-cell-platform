output "instance_name" {
  value       = google_sql_database_instance.primary.name
  description = "Primary instance name."
}

output "private_ip" {
  value       = google_sql_database_instance.primary.private_ip_address
  description = "Primary private IP, reachable only from the cell VPC."
}

output "replica_name" {
  value       = try(google_sql_database_instance.replica[0].name, null)
  description = "Cross-region replica name, or null when DR is not configured."
}

output "replica_private_ip" {
  value       = try(google_sql_database_instance.replica[0].private_ip_address, null)
  description = "Replica private IP — the endpoint the runbook points applications at after promotion."
}

output "password_secret_id" {
  value       = google_secret_manager_secret.db_password.secret_id
  description = "Secret Manager secret holding the application password."
}

output "connection_name" {
  value       = google_sql_database_instance.primary.connection_name
  description = "Instance connection name for the Cloud SQL Auth Proxy."
}
