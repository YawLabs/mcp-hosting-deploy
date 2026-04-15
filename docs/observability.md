# Observability

mcp.hosting exposes Prometheus-style metrics at `/metrics` on the same
port your API is listening on (typically `:3000`). This guide covers
what's exposed, how to scrape it, and the alerts + Grafana dashboard
we ship as a starting point.

## What `/metrics` exposes

The endpoint is **unauthenticated** — standard Prometheus convention.
Don't expose port 3000 to the public internet without something in
front of it (Caddy, an NLB with a restricted allowlist, or a
dedicated internal service).

Metric families:

| Family | Metric | Type | Labels | What to watch |
|--------|--------|------|--------|---------------|
| Proxy | `mcp_proxy_requests_total` | counter | `status_code`, `cached` | Request rate, 5xx rate |
| Proxy | `mcp_proxy_request_duration_ms` | histogram | — | p50/p95/p99 end-to-end latency |
| Proxy | `mcp_proxy_upstream_duration_ms` | histogram | — | Upstream latency (excludes proxy overhead) |
| Proxy | `mcp_proxy_cache_hits_total` / `_misses_total` | counter | — | Cache hit ratio — low ratio means a cold cache or bad keys |
| Proxy | `mcp_proxy_rate_limit_rejections_total` | counter | — | 429 storm indicator |
| Proxy | `mcp_proxy_active_connections` | gauge | — | Connection pool pressure |
| Proxy | `mcp_proxy_auth_failures_total` | counter | `reason` | Auth brute-force / misconfig |
| mcph | `mcp_connect_config_duration_ms` | histogram | `status` | Hot-path latency every mcph CLI client polls |
| mcph | `mcp_connect_analytics_failures_total` | counter | `reason` | DB saturation on analytics ingestion |
| Webhook | `mcp_lemonsqueezy_webhook_total` | counter | `outcome`, `event` | Billing webhook health (hosted only) |
| Webhook | `mcp_webhook_processing_failures_total` | counter | `provider`, `event` | Well-formed webhooks that failed during processing |

Plus the default Node process metrics (`process_cpu_seconds_total`,
`nodejs_heap_size_used_bytes`, event loop lag, open file descriptors,
etc.) via `prom-client`'s `collectDefaultMetrics()`.

Cardinality is bounded intentionally — no per-server or per-account
labels. Per-account analytics come from the dashboard + DB reads, not
Prometheus. See the comment on `proxyRequestsByServer` in
`src/api/metrics.ts` for history.

## Scraping

### Prometheus

```yaml
# prometheus.yml
scrape_configs:
  - job_name: mcp-hosting
    scrape_interval: 30s
    static_configs:
      - targets:
          - mcp-hosting-app.mcp-hosting.svc.cluster.local:3000
```

### Kubernetes / Prometheus Operator

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: mcp-hosting
  namespace: mcp-hosting
spec:
  selector:
    matchLabels:
      app: mcp-hosting-app
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
```

### Docker Compose

If you're running the bundled `docker-compose/compose.yaml`, add a
Prometheus container alongside the app. A minimal example:

```yaml
services:
  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
    ports:
      - "9090:9090"
```

with `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: mcp-hosting
    scrape_interval: 30s
    static_configs:
      - targets: [app:3000]
```

## Grafana dashboard

We ship a starter dashboard at [`grafana/mcp-hosting.json`](../grafana/mcp-hosting.json)
in this repo. Import it:

1. In Grafana: **Dashboards → New → Import**.
2. Paste the JSON or upload the file.
3. Select your Prometheus datasource.

Panels included:

- Request rate (stacked by status code)
- p50 / p95 / p99 end-to-end latency
- Upstream latency p95 vs end-to-end p95 (proxy overhead)
- Cache hit ratio
- Rate-limit 429 rate
- Active connections
- Auth failure rate by reason
- Webhook success/failure rate
- Node memory + event loop lag

## Recommended alerts

The dashboard is a starting point; these are the alerts that would
page someone at 3am on a well-run production deployment. Tune
thresholds to your traffic shape before enabling.

```yaml
groups:
  - name: mcp-hosting
    rules:
      # Serve traffic or not — the one alert you can't turn off.
      - alert: McpHosting5xxRate
        expr: |
          sum(rate(mcp_proxy_requests_total{status_code=~"5.."}[5m]))
            / sum(rate(mcp_proxy_requests_total[5m]))
            > 0.01
        for: 5m
        annotations:
          summary: ">1% 5xx from mcp.hosting proxy"

      # Upstream-ward latency spike (distinguishes app bug vs backend issue).
      - alert: McpHostingUpstreamLatencyHigh
        expr: |
          histogram_quantile(0.95,
            rate(mcp_proxy_upstream_duration_ms_bucket[5m])) > 2000
        for: 10m
        annotations:
          summary: "Upstream p95 > 2s"

      # mcph config polling is a hot path — clients poll every 60s.
      - alert: McpHostingConfigEndpointLatencyHigh
        expr: |
          histogram_quantile(0.95,
            rate(mcp_connect_config_duration_ms_bucket[5m])) > 500
        for: 10m
        annotations:
          summary: "/api/connect/config p95 > 500ms"

      # Auth brute-force — sudden spike in failures usually means an
      # attacker or a broken client. Either way it warrants a look.
      - alert: McpHostingAuthFailureSpike
        expr: |
          sum(rate(mcp_proxy_auth_failures_total[5m])) > 10
        for: 10m
        annotations:
          summary: "Auth failures > 10/s for 10m"

      # Webhook processing failures should be rare; any sustained rate
      # means billing state is drifting from LemonSqueezy.
      - alert: McpHostingWebhookProcessingFailures
        expr: |
          sum(rate(mcp_webhook_processing_failures_total[15m])) > 0
        for: 15m
        annotations:
          summary: "Webhook processing failures sustained"

      # Pods stop scraping entirely.
      - alert: McpHostingTargetDown
        expr: up{job="mcp-hosting"} == 0
        for: 2m
        annotations:
          summary: "mcp-hosting target down for 2m"
```

## Troubleshooting

**`/metrics` returns empty or 404**: check the app is actually running
on the port you're scraping. `/health` must respond on the same port.
Exposing metrics on a separate port isn't supported.

**Scrape succeeds but all counters read zero**: the counters are
populated by the proxy, webhook, and auth code paths. A fresh pod
that has received no traffic will legitimately show zeros. Generate
one request and re-scrape.

**Prometheus memory balloons**: you're probably on an older version
that added per-subdomain labels. Upgrade to v0.9.0+ where the
`*_by_server` aggregate metric replaced the high-cardinality one.
