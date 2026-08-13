output "keys" {
  value       = { for name, key in google_kms_crypto_key.this : name => key.id }
  description = "Map of logical key name (gke, sql, storage, secrets) to fully-qualified key id."
}

output "key_ring_id" {
  value       = google_kms_key_ring.this.id
  description = "Fully-qualified key ring id."
}
