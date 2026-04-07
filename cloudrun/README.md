# Deploy to Google Cloud Run

Cloud Run provides a fully managed serverless container platform with automatic TLS, scaling, and pay-per-use pricing.

## Prerequisites

- [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) (`gcloud`)
- A GCP project with billing enabled
- Cloud SQL PostgreSQL instance (or use [Cloud SQL Auth Proxy](https://cloud.google.com/sql/docs/postgres/connect-run))
- Memorystore Redis instance (or use the Valkey sidecar pattern)

## Deploy

```bash
# Authenticate
gcloud auth login
gcloud config set project YOUR_PROJECT_ID

# Deploy the service
gcloud run deploy mcp-hosting \
  --image ghcr.io/yawlabs/mcp-hosting:latest \
  --platform managed \
  --region us-central1 \
  --port 3000 \
  --allow-unauthenticated \
  --min-instances 1 \
  --max-instances 10 \
  --cpu 1 \
  --memory 512Mi \
  --timeout 3600 \
  --set-env-vars "NODE_ENV=production" \
  --set-env-vars "BASE_URL=https://mcp.example.com" \
  --set-env-vars "DOMAIN=mcp.example.com" \
  --set-env-vars "REDIS_URL=redis://REDIS_HOST:6379" \
  --set-secrets "DATABASE_URL=mcp-hosting-db-url:latest" \
  --set-secrets "COOKIE_SECRET=mcp-hosting-cookie-secret:latest" \
  --set-secrets "MCP_HOSTING_LICENSE_KEY=mcp-hosting-license-key:latest"
```

## Secrets

Store sensitive values in [Secret Manager](https://cloud.google.com/secret-manager):

```bash
echo -n "postgresql://user:pass@host:5432/mcphosting" | \
  gcloud secrets create mcp-hosting-db-url --data-file=-

echo -n "$(openssl rand -hex 32)" | \
  gcloud secrets create mcp-hosting-cookie-secret --data-file=-
```

## Custom domain

1. Map your domain in Cloud Run: `gcloud run domain-mappings create --service mcp-hosting --domain mcp.example.com`
2. Add the DNS records shown by the command
3. For wildcard subdomains (`*.mcp.example.com`), use a load balancer with Cloud Run as the backend

## Notes

- Cloud Run natively handles TLS, so Caddy is not needed
- SSE / Streamable HTTP connections work with `--timeout 3600`
- Set `--cpu-throttling=false` to keep the CPU always allocated (required for background tasks)
- For wildcard subdomain routing, use [Cloud Run with a global external Application Load Balancer](https://cloud.google.com/run/docs/mapping-custom-domains#https-load-balancer)
