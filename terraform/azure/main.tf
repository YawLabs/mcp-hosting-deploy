# =============================================================================
# Azure deployment for mcp.hosting
# =============================================================================
# Provisions: Resource Group, Container Instances (app + Caddy + Valkey),
#             Azure Database for PostgreSQL Flexible Server,
#             Azure Cache for Redis, VNet, NSG.
# =============================================================================

terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# -----------------------------------------------------------------------------
# Resource Group
# -----------------------------------------------------------------------------

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# -----------------------------------------------------------------------------
# Virtual Network
# -----------------------------------------------------------------------------

resource "azurerm_virtual_network" "main" {
  name                = "mcp-hosting-vnet"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.0.0.0/16"]
  tags                = var.tags
}

# Subnet for Container Instances
resource "azurerm_subnet" "aci" {
  name                 = "mcp-hosting-aci-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]

  delegation {
    name = "aci-delegation"
    service_delegation {
      name    = "Microsoft.ContainerInstance/containerGroups"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# Subnet for PostgreSQL
resource "azurerm_subnet" "postgres" {
  name                 = "mcp-hosting-postgres-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]

  delegation {
    name = "postgres-delegation"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Subnet for Redis
resource "azurerm_subnet" "redis" {
  name                 = "mcp-hosting-redis-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.3.0/24"]
}

# Private DNS zone for PostgreSQL
resource "azurerm_private_dns_zone" "postgres" {
  name                = "mcp-hosting.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "mcp-hosting-postgres-dns-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.main.id
}

# -----------------------------------------------------------------------------
# Network Security Group
# -----------------------------------------------------------------------------

resource "azurerm_network_security_group" "main" {
  name                = "mcp-hosting-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  security_rule {
    name                       = "allow-http"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-https"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "aci" {
  subnet_id                 = azurerm_subnet.aci.id
  network_security_group_id = azurerm_network_security_group.main.id
}

# -----------------------------------------------------------------------------
# Azure Database for PostgreSQL Flexible Server
# -----------------------------------------------------------------------------

resource "azurerm_postgresql_flexible_server" "main" {
  name                          = "mcp-hosting-postgres"
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  version                       = "17" # 18 not yet available on Azure Flexible Server; 17 is latest
  administrator_login           = "mcphosting"
  administrator_password        = var.db_password
  sku_name                      = "B_Standard_B1ms"
  storage_mb                    = 32768
  delegated_subnet_id           = azurerm_subnet.postgres.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false
  zone                          = "1"
  tags                          = var.tags

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]
}

resource "azurerm_postgresql_flexible_server_database" "main" {
  name      = "mcphosting"
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# -----------------------------------------------------------------------------
# Azure Cache for Redis
# -----------------------------------------------------------------------------

resource "azurerm_redis_cache" "main" {
  name                          = "mcp-hosting-redis"
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  capacity                      = 0
  family                        = "C"
  sku_name                      = "Basic"
  non_ssl_port_enabled          = true
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false
  tags                          = var.tags
}

# Private endpoint for Redis
resource "azurerm_private_endpoint" "redis" {
  name                = "mcp-hosting-redis-pe"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.redis.id
  tags                = var.tags

  private_service_connection {
    name                           = "mcp-hosting-redis-psc"
    private_connection_resource_id = azurerm_redis_cache.main.id
    subresource_names              = ["redisCache"]
    is_manual_connection           = false
  }
}

# -----------------------------------------------------------------------------
# Azure Container Instances -- app + Caddy + Valkey sidecar
# -----------------------------------------------------------------------------

resource "azurerm_container_group" "main" {
  name                = "mcp-hosting"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  os_type             = "Linux"
  ip_address_type     = "Private"
  subnet_ids          = [azurerm_subnet.aci.id]
  restart_policy      = "Always"
  tags                = var.tags

  # -------------------------------------------------------------------------
  # mcp-hosting app container
  # -------------------------------------------------------------------------
  container {
    name   = "mcp-hosting-app"
    image  = "ghcr.io/yawlabs/mcp-hosting:latest"
    cpu    = 1
    memory = 1

    ports {
      port     = 3000
      protocol = "TCP"
    }

    environment_variables = {
      DOMAIN    = var.domain
      BASE_URL  = "https://${var.domain}"
      REDIS_URL = "redis://${azurerm_redis_cache.main.hostname}:6379"
    }

    secure_environment_variables = {
      DATABASE_URL            = "postgresql://mcphosting:${var.db_password}@${azurerm_postgresql_flexible_server.main.fqdn}:5432/mcphosting?sslmode=require"
      MCP_HOSTING_LICENSE_KEY = var.license_key
      COOKIE_SECRET           = var.cookie_secret
    }
  }

  # -------------------------------------------------------------------------
  # Caddy reverse proxy + TLS
  # -------------------------------------------------------------------------
  container {
    name   = "caddy"
    image  = "caddy:2"
    cpu    = 0.5
    memory = 0.5

    ports {
      port     = 80
      protocol = "TCP"
    }

    ports {
      port     = 443
      protocol = "TCP"
    }

    environment_variables = {
      DOMAIN = var.domain
    }

    secure_environment_variables = {
      CF_API_TOKEN = var.cf_api_token
    }

    # Mount Caddyfile via volume
    volume {
      name       = "caddy-config"
      mount_path = "/etc/caddy"
      secret = {
        # Base64-encoded Caddyfile -- Caddy reverse-proxies to localhost:3000
        "Caddyfile" = base64encode(<<-CADDYFILE
          {$DOMAIN} {
            reverse_proxy localhost:3000 {
              flush_interval -1
              transport http {
                response_header_timeout 0
                dial_timeout 30s
                read_timeout 3600s
                write_timeout 3600s
              }
            }
          }

          *.{$DOMAIN} {
            tls {
              dns cloudflare {env.CF_API_TOKEN}
            }

            reverse_proxy localhost:3000 {
              flush_interval -1
              transport http {
                response_header_timeout 0
                dial_timeout 30s
                read_timeout 3600s
                write_timeout 3600s
              }
            }
          }
        CADDYFILE
        )
      }
    }
  }

  depends_on = [
    azurerm_postgresql_flexible_server_database.main,
    azurerm_redis_cache.main,
  ]
}
