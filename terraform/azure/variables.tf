# =============================================================================
# Variables -- Azure deployment for mcp.hosting
# =============================================================================

variable "domain" {
  description = "Primary domain for mcp.hosting (e.g. mcp.example.com)"
  type        = string
}

variable "license_key" {
  description = "mcp.hosting license key"
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "Password for the PostgreSQL Flexible Server (min 8 chars, mixed case + numbers)"
  type        = string
  sensitive   = true
}

variable "cookie_secret" {
  description = "Secret used to sign session cookies (random 32+ char string)"
  type        = string
  sensitive   = true
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Name of the Azure Resource Group"
  type        = string
  default     = "mcp-hosting-rg"
}

variable "cf_api_token" {
  description = "Cloudflare API token for wildcard TLS certs via Caddy (optional)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Project   = "mcp-hosting"
    ManagedBy = "terraform"
  }
}
