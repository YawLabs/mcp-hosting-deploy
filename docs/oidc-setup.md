# OIDC SSO setup

When `OIDC_ISSUER`, `OIDC_CLIENT_ID`, and `OIDC_CLIENT_SECRET` are all set, the sign-in page shows a **Sign in with SSO** button that delegates authentication to your OIDC provider. Magic-link email and (optional) GitHub OAuth continue to work alongside SSO — operators decide which to expose to end users.

OIDC is **off by default**. Leave the three env vars unset to disable.

## Prerequisites

- An OIDC-compliant identity provider (Google Workspace, Okta, Azure AD / Entra ID, Authentik, Keycloak, Auth0, etc.).
- The ability to register a new OIDC application in that provider's admin console.
- Your self-hosted instance reachable at `https://<DOMAIN>` (HTTPS is mandatory — providers reject HTTP redirect URIs).

## Callback URL

The redirect URI you register with the provider is:

```
https://<DOMAIN>/auth/oidc/callback
```

Replace `<DOMAIN>` with the value of `DOMAIN` in `.env` (Compose) or `domain` in `values.yaml` (Helm). For example, `https://mcp.example.com/auth/oidc/callback`.

> If your provider rejects the callback URL or returns `redirect_uri_mismatch` after sign-in, sign in with another method first and check the dashboard logs — the exact URI the app sends is logged on each OIDC redirect attempt. Match it character-for-character in the provider's allowed-redirect list.

## Provider walkthroughs

### Google Workspace

1. Go to [Google Cloud Console → APIs & Services → Credentials](https://console.cloud.google.com/apis/credentials).
2. **Create credentials → OAuth client ID → Web application.**
3. **Authorised redirect URIs:** add `https://<DOMAIN>/auth/oidc/callback`.
4. Save. Google shows a client ID + secret.
5. Set the env vars:

   ```
   OIDC_ISSUER=https://accounts.google.com
   OIDC_CLIENT_ID=<from step 4>
   OIDC_CLIENT_SECRET=<from step 4>
   ```

To restrict sign-in to your Workspace domain, configure a [Cloud Identity policy](https://support.google.com/cloudidentity/answer/6304947) — the app trusts whatever Google returns.

### Okta

1. Okta admin console → **Applications → Create App Integration → OIDC - OpenID Connect → Web Application.**
2. **Sign-in redirect URIs:** `https://<DOMAIN>/auth/oidc/callback`.
3. **Sign-out redirect URIs:** `https://<DOMAIN>` (optional but recommended).
4. Assign the app to the users/groups who should be able to sign in.
5. After save, copy the **Client ID** and **Client secret** from the General tab.
6. Set the env vars:

   ```
   OIDC_ISSUER=https://<your-tenant>.okta.com
   OIDC_CLIENT_ID=<from step 5>
   OIDC_CLIENT_SECRET=<from step 5>
   ```

`OIDC_ISSUER` is the base tenant URL — no trailing slash, no `/oauth2/default` suffix. The app does the OIDC discovery from that root.

### Azure AD / Microsoft Entra ID

1. Azure portal → **Microsoft Entra ID → App registrations → New registration.**
2. **Name:** mcp.hosting (or whatever you want users to see at consent).
3. **Supported account types:** typically *Single tenant* unless you serve users from multiple tenants.
4. **Redirect URI:** *Web* + `https://<DOMAIN>/auth/oidc/callback`.
5. After registration, copy the **Application (client) ID** and the **Directory (tenant) ID**.
6. **Certificates & secrets → New client secret** → copy the secret value (Azure only shows it once).
7. Set the env vars:

   ```
   OIDC_ISSUER=https://login.microsoftonline.com/<TENANT_ID>/v2.0
   OIDC_CLIENT_ID=<application/client ID>
   OIDC_CLIENT_SECRET=<client secret value>
   ```

The trailing `/v2.0` is required — the v1 endpoint uses a different token shape that the app doesn't parse.

### Authentik / Keycloak / generic OIDC

Any OIDC-compliant provider works. The provider must:

- Expose an OIDC discovery document at `<OIDC_ISSUER>/.well-known/openid-configuration`.
- Support the `authorization_code` grant.
- Return `email`, `email_verified`, and `sub` claims in the ID token (the app uses `sub` as the stable identifier and `email` to populate the account).

Set the three env vars to the values from your provider:

```
OIDC_ISSUER=https://auth.example.com/application/o/mcp-hosting/
OIDC_CLIENT_ID=...
OIDC_CLIENT_SECRET=...
```

Trailing-slash sensitivity varies by provider — match exactly what the discovery document advertises.

## Applying the configuration

### Docker Compose

Edit `docker-compose/.env`, uncomment the OIDC block, and fill in all three values. Then:

```bash
docker compose up -d --force-recreate mcp-hosting-app
```

Force-recreate ensures the container restarts with the new env vars even if nothing else changed.

### Helm

Set the OIDC values in `values.yaml` (or pass them on `helm upgrade --set`):

```yaml
oidc:
  issuer: https://accounts.google.com
  clientId: "your-client-id"
  clientSecret: "your-client-secret"
```

Apply:

```bash
helm upgrade mcp-hosting helm/mcp-hosting -f values.yaml
```

The chart writes all three into the app `Secret` and rolls the deployment via the secret-checksum annotation.

### Cloud Run

Add three more secrets to Secret Manager and reference them in `--set-secrets`:

```bash
echo -n "https://accounts.google.com" | gcloud secrets create mcp-hosting-oidc-issuer --data-file=-
echo -n "<client id>"                  | gcloud secrets create mcp-hosting-oidc-client-id --data-file=-
echo -n "<client secret>"              | gcloud secrets create mcp-hosting-oidc-client-secret --data-file=-

# Grant access (compute SA — same pattern as the other secrets)
SA="$(gcloud projects describe YOUR_PROJECT_ID --format='value(projectNumber)')-compute@developer.gserviceaccount.com"
for s in oidc-issuer oidc-client-id oidc-client-secret; do
  gcloud secrets add-iam-policy-binding "mcp-hosting-${s}" \
    --member="serviceAccount:${SA}" --role=roles/secretmanager.secretAccessor
done

gcloud run services update mcp-hosting \
  --region=us-central1 \
  --update-secrets="OIDC_ISSUER=mcp-hosting-oidc-issuer:latest,OIDC_CLIENT_ID=mcp-hosting-oidc-client-id:latest,OIDC_CLIENT_SECRET=mcp-hosting-oidc-client-secret:latest"
```

### Fly.io

```bash
fly secrets set \
  OIDC_ISSUER=https://accounts.google.com \
  OIDC_CLIENT_ID=... \
  OIDC_CLIENT_SECRET=...
```

`fly secrets set` triggers a rolling restart automatically.

## Verification

1. Open `https://<DOMAIN>` in a private/incognito window.
2. The sign-in page should now show a **Sign in with SSO** button alongside the magic-link form.
3. Click it — you should be redirected to your provider, sign in, and end up back at the dashboard signed in as your OIDC identity's email.

If the SSO button doesn't appear, all three env vars are NOT set — partially-set OIDC config is treated as off (and logs a warning).

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| **No Sign in with SSO button** | One or more of the three env vars is missing/empty | All three must be set together. Check `docker compose config` (Compose) or `kubectl get secret` (Helm) for the actual rendered values. |
| **`redirect_uri_mismatch`** after provider sign-in | Callback URL registered with the provider doesn't match what the app sends | Check app logs for the actual `redirect_uri` value, then add it verbatim to the provider's allowed-redirect list. |
| **`invalid_client`** at the token-exchange step | `OIDC_CLIENT_SECRET` is wrong, or the app is registered as a "public" client (no secret) instead of "confidential" | Re-copy the secret from the provider; if the provider used "public client", recreate as "web application" / "confidential". |
| **Provider sign-in works, then dashboard 500s** | ID token is missing the `email` claim | Add `email` to the requested scopes in the provider's app config (Google/Okta/Azure all default to including it; custom IdPs often don't). |
| **`OIDC discovery failed`** in app logs | `OIDC_ISSUER` isn't reachable from the app, or `.well-known/openid-configuration` doesn't exist at that URL | `curl <OIDC_ISSUER>/.well-known/openid-configuration` from the same network as the app — the JSON should describe the provider. Trailing-slash mismatches are the usual culprit. |
| **OIDC sign-in succeeds but creates a new account each time** | Provider is rotating the `sub` claim instead of returning a stable identifier | Check provider config — `sub` must be stable per user across sessions. Most providers do this by default; some let you misconfigure it. |

## Disabling OIDC

Unset all three env vars and restart the app. Existing users who signed in via SSO can continue to sign in via magic-link email (the account is keyed by email address, not by auth method).
