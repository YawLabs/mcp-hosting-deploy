# =============================================================================
# Outputs -- GCP deployment
# =============================================================================

output "app_public_ip" {
  description = "Public IP of the GCE instance -- point your DNS here"
  value       = google_compute_instance.app.network_interface[0].access_config[0].nat_ip
}

output "cloud_sql_private_ip" {
  description = "Cloud SQL PostgreSQL private IP"
  value       = google_sql_database_instance.postgres.private_ip_address
}

output "memorystore_host" {
  description = "Memorystore Redis host"
  value       = google_redis_instance.main.host
}

output "next_steps" {
  description = "What to do after terraform apply"
  value       = <<-EOT
    1. Point DNS for ${var.domain} and *.${var.domain} to ${google_compute_instance.app.network_interface[0].access_config[0].nat_ip}
    2. SSH via IAP: gcloud compute ssh mcp-hosting-app --zone=${var.zone}
    3. Check startup script: sudo journalctl -u google-startup-scripts -f
    4. Verify: curl https://${var.domain}/health
  EOT
}
