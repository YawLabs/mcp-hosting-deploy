# =============================================================================
# Variables -- GCP deployment for mcp.hosting
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
  description = "Password for the Cloud SQL PostgreSQL database"
  type        = string
  sensitive   = true
}

variable "cookie_secret" {
  description = "Secret used to sign session cookies (random 32+ char string)"
  type        = string
  sensitive   = true
}

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone (must be in the selected region)"
  type        = string
  default     = "us-central1-a"
}

variable "machine_type" {
  description = "GCE instance machine type"
  type        = string
  default     = "e2-small"
}

variable "db_tier" {
  description = "Cloud SQL machine tier"
  type        = string
  default     = "db-f1-micro"
}

variable "cf_api_token" {
  description = "Cloudflare API token for wildcard TLS certs via Caddy (optional)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "labels" {
  description = "Labels applied to all resources"
  type        = map(string)
  default = {
    project    = "mcp-hosting"
    managed-by = "terraform"
  }
}
