# =============================================================================
# Variables -- AWS deployment for mcp.hosting
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
  description = "Password for the RDS PostgreSQL database"
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

variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type for the app server"
  type        = string
  default     = "t4g.small"
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"
}

variable "cache_node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t4g.micro"
}

variable "use_default_vpc" {
  description = "Use the default VPC instead of creating a new one"
  type        = bool
  default     = true
}

variable "ssh_key_name" {
  description = "Name of an existing EC2 key pair for SSH access (optional)"
  type        = string
  default     = ""
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH into the instance (e.g. 203.0.113.10/32)"
  type        = string
  default     = ""

  validation {
    condition     = var.allowed_ssh_cidr == "" || can(cidrhost(var.allowed_ssh_cidr, 0))
    error_message = "allowed_ssh_cidr must be a valid CIDR block (e.g. 203.0.113.10/32). Never use 0.0.0.0/0."
  }
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
