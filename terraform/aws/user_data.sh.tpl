#!/bin/bash
set -euo pipefail

# =============================================================================
# EC2 user-data: install Docker, pull mcp-hosting-deploy, start services
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

# Wait for apt lock
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done

# Install Docker
apt-get update -y
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable docker
usermod -aG docker ubuntu

# Clone the deploy repo
apt-get install -y git
git clone https://github.com/yawlabs/mcp-hosting-deploy.git /opt/mcp-hosting
cd /opt/mcp-hosting/docker-compose

# Write the .env file with values from Terraform
cat > .env <<'ENVEOF'
DOMAIN=${domain}
MCP_HOSTING_LICENSE_KEY=${license_key}
DATABASE_URL=postgresql://mcphosting:${db_password}@${db_host}:5432/mcphosting
REDIS_URL=redis://${redis_host}:6379
COOKIE_SECRET=${cookie_secret}
BASE_URL=https://${domain}
CF_API_TOKEN=${cf_api_token}
ENVEOF

chmod 600 .env

# When using external RDS + ElastiCache, remove the local postgres and redis
# services from docker-compose so we only run the app + caddy
cat > docker-compose.override.yml <<'OVERRIDE'
services:
  postgres:
    profiles: ["disabled"]
  redis:
    profiles: ["disabled"]
  mcp-hosting-app:
    depends_on: {}
OVERRIDE

# Start the app
docker compose up -d
