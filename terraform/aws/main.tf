# =============================================================================
# AWS deployment for mcp.hosting
# =============================================================================
# Provisions: VPC (or default), EC2 + Docker, RDS PostgreSQL 18,
#             ElastiCache Valkey, security groups.
# =============================================================================

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# -----------------------------------------------------------------------------
# Data sources
# -----------------------------------------------------------------------------

# Latest Ubuntu 24.04 LTS ARM64 AMI (for Graviton / t4g instances)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Look up default VPC if requested
data "aws_vpc" "default" {
  count   = var.use_default_vpc ? 1 : 0
  default = true
}

data "aws_subnets" "default" {
  count = var.use_default_vpc ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }
}

# -----------------------------------------------------------------------------
# VPC (only created when use_default_vpc = false)
# -----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  count                = var.use_default_vpc ? 0 : 1
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "mcp-hosting-vpc" })
}

resource "aws_internet_gateway" "main" {
  count  = var.use_default_vpc ? 0 : 1
  vpc_id = aws_vpc.main[0].id
  tags   = merge(var.tags, { Name = "mcp-hosting-igw" })
}

resource "aws_subnet" "public" {
  count                   = var.use_default_vpc ? 0 : 2
  vpc_id                  = aws_vpc.main[0].id
  cidr_block              = cidrsubnet("10.0.0.0/16", 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags                    = merge(var.tags, { Name = "mcp-hosting-public-${count.index}" })
}

resource "aws_subnet" "private" {
  count             = var.use_default_vpc ? 0 : 2
  vpc_id            = aws_vpc.main[0].id
  cidr_block        = cidrsubnet("10.0.0.0/16", 8, count.index + 100)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = merge(var.tags, { Name = "mcp-hosting-private-${count.index}" })
}

resource "aws_route_table" "public" {
  count  = var.use_default_vpc ? 0 : 1
  vpc_id = aws_vpc.main[0].id
  tags   = merge(var.tags, { Name = "mcp-hosting-public-rt" })

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main[0].id
  }
}

resource "aws_route_table_association" "public" {
  count          = var.use_default_vpc ? 0 : 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

# Resolve VPC / subnet IDs regardless of mode
locals {
  vpc_id     = var.use_default_vpc ? data.aws_vpc.default[0].id : aws_vpc.main[0].id
  subnet_ids = var.use_default_vpc ? data.aws_subnets.default[0].ids : aws_subnet.public[*].id
  private_subnet_ids = var.use_default_vpc ? data.aws_subnets.default[0].ids : aws_subnet.private[*].id
}

# -----------------------------------------------------------------------------
# Security Groups
# -----------------------------------------------------------------------------

# EC2: allow HTTP, HTTPS, and optionally SSH
resource "aws_security_group" "app" {
  name_prefix = "mcp-hosting-app-"
  description = "Allow HTTP/HTTPS inbound, all outbound"
  vpc_id      = local.vpc_id
  tags        = merge(var.tags, { Name = "mcp-hosting-app-sg" })

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  dynamic "ingress" {
    for_each = var.ssh_key_name != "" ? [1] : []
    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [var.allowed_ssh_cidr]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# RDS: only accessible from the app security group
resource "aws_security_group" "rds" {
  name_prefix = "mcp-hosting-rds-"
  description = "Allow PostgreSQL from app SG"
  vpc_id      = local.vpc_id
  tags        = merge(var.tags, { Name = "mcp-hosting-rds-sg" })

  ingress {
    description     = "PostgreSQL from app"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ElastiCache: only accessible from the app security group
resource "aws_security_group" "cache" {
  name_prefix = "mcp-hosting-cache-"
  description = "Allow Valkey/Redis from app SG"
  vpc_id      = local.vpc_id
  tags        = merge(var.tags, { Name = "mcp-hosting-cache-sg" })

  ingress {
    description     = "Valkey from app"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# RDS PostgreSQL 18
# -----------------------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name_prefix = "mcp-hosting-"
  subnet_ids  = local.private_subnet_ids
  tags        = merge(var.tags, { Name = "mcp-hosting-db-subnet" })
}

resource "aws_db_instance" "postgres" {
  identifier_prefix      = "mcp-hosting-"
  engine                 = "postgres"
  engine_version         = "18"
  instance_class         = var.db_instance_class
  allocated_storage      = 20
  storage_type           = "gp3"
  db_name                = "mcphosting"
  username               = "mcphosting"
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  skip_final_snapshot    = true
  publicly_accessible    = false
  multi_az               = false
  tags                   = merge(var.tags, { Name = "mcp-hosting-postgres" })
}

# -----------------------------------------------------------------------------
# ElastiCache Valkey
# -----------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "main" {
  name       = "mcp-hosting-cache-subnet"
  subnet_ids = local.private_subnet_ids
  tags       = merge(var.tags, { Name = "mcp-hosting-cache-subnet" })
}

resource "aws_elasticache_cluster" "valkey" {
  cluster_id         = "mcp-hosting"
  engine             = "valkey"
  node_type          = var.cache_node_type
  num_cache_nodes    = 1
  port               = 6379
  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.cache.id]
  tags               = merge(var.tags, { Name = "mcp-hosting-valkey" })
}

# -----------------------------------------------------------------------------
# EC2 Instance -- runs Docker Compose
# -----------------------------------------------------------------------------

resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = local.subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = var.ssh_key_name != "" ? var.ssh_key_name : null

  associate_public_ip_address = true

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    domain           = var.domain
    license_key      = var.license_key
    db_host          = aws_db_instance.postgres.address
    db_password      = var.db_password
    redis_host       = aws_elasticache_cluster.valkey.cache_nodes[0].address
    cookie_secret    = var.cookie_secret
    cf_api_token     = var.cf_api_token
  }))

  tags = merge(var.tags, { Name = "mcp-hosting-app" })

  depends_on = [
    aws_db_instance.postgres,
    aws_elasticache_cluster.valkey,
  ]
}
