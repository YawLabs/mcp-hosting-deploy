# =============================================================================
# Variables -- Azure deployment for mcp.hosting
# =============================================================================

variable "domain" {
  description = "Primary domain for mcp.hosting (e.g. mcp.example.com)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]+[a-z0-9]$", var.domain))
    error_message = "domain must be a valid hostname (e.g. mcp.example.com)."
  }
}

variable "license_key" {
  description = "mcp.hosting license key"
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "Password for the PostgreSQL Flexible Server (min 16 chars, mixed case + numbers)"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.db_password) >= 16
    error_message = "db_password must be at least 16 characters."
  }
}

variable "cookie_secret" {
  description = "Secret used to sign session cookies (random 32+ char string)"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.cookie_secret) >= 32
    error_message = "cookie_secret must be at least 32 characters. Generate with: openssl rand -hex 32"
  }
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
