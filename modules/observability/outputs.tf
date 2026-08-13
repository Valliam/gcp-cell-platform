output "audit_sink_writer_identity" {
  value       = google_logging_project_sink.audit.writer_identity
  description = "Service account the sink writes as. stacks/org grants this objectCreator on the audit bucket."
}

output "notification_channel_ids" {
  value       = { for name, c in google_monitoring_notification_channel.this : name => c.id }
  description = "Channel ids, so other modules can attach their own alerts."
}

output "slo_id" {
  value       = try(google_monitoring_slo.availability[0].id, null)
  description = "Availability SLO id, or null when the cell declares no uptime check host."
}
