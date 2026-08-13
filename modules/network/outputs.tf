output "network_id" {
  value       = google_compute_network.this.id
  description = "Fully-qualified VPC id."
}

output "network_self_link" {
  value       = google_compute_network.this.self_link
  description = "VPC self link, required by Cloud SQL private IP configuration."
}

output "subnetwork_id" {
  value       = google_compute_subnetwork.primary.id
  description = "Primary subnet id."
}

output "pods_range_name" {
  value       = "pods"
  description = "Secondary range name for pods."
}

output "services_range_name" {
  value       = "services"
  description = "Secondary range name for services."
}

output "nat_ips" {
  value       = google_compute_address.nat[*].address
  description = "Static egress addresses. Give these to partners for allowlisting."
}

output "psa_connection" {
  value       = google_service_networking_connection.psa.id
  description = "Handle to depend on before creating Cloud SQL instances with private IP."
}
