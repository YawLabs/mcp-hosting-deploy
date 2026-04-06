# =============================================================================
# Outputs -- Azure deployment
# =============================================================================

output "container_group_ip" {
  description = "Private IP of the container group (use a load balancer or Application Gateway for public access)"
  value       = azurerm_container_group.main.ip_address
}

output "postgres_fqdn" {
  description = "PostgreSQL Flexible Server FQDN"
  value       = azurerm_postgresql_flexible_server.main.fqdn
}

output "redis_hostname" {
  description = "Azure Cache for Redis hostname"
  value       = azurerm_redis_cache.main.hostname
}

output "resource_group" {
  description = "Resource group name"
  value       = azurerm_resource_group.main.name
}

output "next_steps" {
  description = "What to do after terraform apply"
  value       = <<-EOT
    1. The container group has a private IP. To expose it publicly, add an
       Azure Application Gateway or Azure Front Door in front of it, or
       switch ip_address_type to "Public" (removes VNet integration).
    2. Point DNS for ${var.domain} and *.${var.domain} to the public endpoint.
    3. Verify: curl https://${var.domain}/health
  EOT
}
