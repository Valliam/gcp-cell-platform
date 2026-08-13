output "cluster_id" {
  value       = google_container_cluster.this.id
  description = "Fully-qualified cluster id."
}

output "cluster_name" {
  value       = google_container_cluster.this.name
  description = "Cluster name."
}

output "endpoint" {
  value       = google_container_cluster.this.endpoint
  description = "Control plane endpoint. Private when enable_private_endpoint is true."
  sensitive   = true
}

output "workload_identity_pool" {
  value       = "${var.project_id}.svc.id.goog"
  description = "Workload Identity pool, for binding Kubernetes SAs to Google SAs."
}

output "membership_id" {
  value       = google_gke_hub_membership.this.membership_id
  description = "Fleet membership id, used by Connect Gateway to reach a private control plane."
}
