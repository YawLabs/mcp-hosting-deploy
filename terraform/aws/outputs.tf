# =============================================================================
# Outputs -- AWS deployment
# =============================================================================

output "app_public_ip" {
  description = "Public IP of the EC2 instance -- point your DNS here"
  value       = aws_instance.app.public_ip
}

output "app_public_dns" {
  description = "Public DNS of the EC2 instance"
  value       = aws_instance.app.public_dns
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (host:port)"
  value       = aws_db_instance.postgres.endpoint
}

output "elasticache_endpoint" {
  description = "ElastiCache Valkey endpoint"
  value       = aws_elasticache_replication_group.valkey.primary_endpoint_address
}

output "instance_id" {
  description = "EC2 instance ID (for SSM Session Manager access)"
  value       = aws_instance.app.id
}

output "next_steps" {
  description = "What to do after terraform apply"
  value       = <<-EOT
    1. Point DNS for ${var.domain} and *.${var.domain} to ${aws_instance.app.public_ip}
    2. SSH in (if key provided): ssh ubuntu@${aws_instance.app.public_ip}
    3. Check cloud-init progress: sudo cloud-init status --wait
    4. Verify: curl https://${var.domain}/health
  EOT
}
