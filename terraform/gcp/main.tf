# =============================================================================
# GCP deployment for mcp.hosting
# =============================================================================
# Provisions: GCE instance + Docker, Cloud SQL PostgreSQL 18,
#             Memorystore Redis, firewall rules.
# =============================================================================

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.26"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# -----------------------------------------------------------------------------
# Enable required APIs
# -----------------------------------------------------------------------------

resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "sqladmin.googleapis.com",
    "redis.googleapis.com",
    "servicenetworking.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

# -----------------------------------------------------------------------------
# VPC Network -- simple setup with one subnet
# -----------------------------------------------------------------------------

resource "google_compute_network" "main" {
  name                    = "mcp-hosting-network"
  auto_create_subnetworks = false

  depends_on = [google_project_service.apis]
}

resource "google_compute_subnetwork" "main" {
  name          = "mcp-hosting-subnet"
  network       = google_compute_network.main.id
  ip_cidr_range = "10.0.0.0/24"
  region        = var.region
}

# Private services access for Cloud SQL and Memorystore
resource "google_compute_global_address" "private_ip" {
  name          = "mcp-hosting-private-ip"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.main.id
}

resource "google_service_networking_connection" "private" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip.name]

  depends_on = [google_project_service.apis]
}

# -----------------------------------------------------------------------------
# Firewall Rules
# -----------------------------------------------------------------------------

resource "google_compute_firewall" "allow_http_https" {
  name    = "mcp-hosting-allow-http-https"
  network = google_compute_network.main.id

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["mcp-hosting"]
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "mcp-hosting-allow-ssh"
  network = google_compute_network.main.id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # IAP tunnel range -- safer than opening to the world
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["mcp-hosting"]
}

# -----------------------------------------------------------------------------
# Cloud SQL PostgreSQL 18
# -----------------------------------------------------------------------------

resource "google_sql_database_instance" "postgres" {
  name             = "mcp-hosting-postgres"
  database_version = "POSTGRES_18"
  region           = var.region

  settings {
    tier              = var.db_tier
    availability_type = "ZONAL"
    disk_size         = 20
    disk_type         = "PD_SSD"

    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = google_compute_network.main.id
      enable_private_path_for_google_cloud_services = true
    }

    user_labels = var.labels
  }

  deletion_protection = false

  depends_on = [google_service_networking_connection.private]
}

resource "google_sql_database" "main" {
  name     = "mcphosting"
  instance = google_sql_database_instance.postgres.name
}

resource "google_sql_user" "main" {
  name     = "mcphosting"
  instance = google_sql_database_instance.postgres.name
  password = var.db_password
}

# -----------------------------------------------------------------------------
# Memorystore Redis (Valkey-compatible)
# -----------------------------------------------------------------------------

resource "google_redis_instance" "main" {
  name               = "mcp-hosting-redis"
  tier               = "BASIC"
  memory_size_gb     = 1
  region             = var.region
  authorized_network = google_compute_network.main.id
  redis_version      = "REDIS_7_2"

  labels = var.labels

  depends_on = [google_project_service.apis]
}

# -----------------------------------------------------------------------------
# GCE Instance -- runs Docker Compose
# -----------------------------------------------------------------------------

resource "google_compute_instance" "app" {
  name         = "mcp-hosting-app"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["mcp-hosting"]

  labels = var.labels

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = 30
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id

    access_config {
      # Ephemeral public IP
    }
  }

  metadata_startup_script = templatefile("${path.module}/startup.sh.tpl", {
    domain        = var.domain
    license_key   = var.license_key
    db_host       = google_sql_database_instance.postgres.private_ip_address
    db_password   = var.db_password
    redis_host    = google_redis_instance.main.host
    cookie_secret = var.cookie_secret
    cf_api_token  = var.cf_api_token
  })

  service_account {
    scopes = ["cloud-platform"]
  }

  depends_on = [
    google_sql_database_instance.postgres,
    google_redis_instance.main,
  ]
}
