# Fluxer Self-Hosted Deployment Guide

Deployment log for Fluxer on `fluxer.mydomain.net` — a free, open-source Discord alternative (AGPLv3).

## Architecture

Fluxer runs as a **monolith** Docker Compose stack with 6 containers:

| Container | Image | Purpose |
|---|---|---|
| `fluxer-server` | Built from source | API, WebSocket gateway (Erlang/OTP), media proxy, admin panel, SPA web app |
| `fluxer-valkey` | `valkey/valkey:8.0.6-alpine` | Redis-compatible cache/session store |
| `fluxer-meilisearch` | `getmeili/meilisearch:v1.14` | Full-text search engine |
| `fluxer-livekit` | `livekit/livekit-server:v1.9.11` | Voice/video SFU (WebRTC) |
| `fluxer-nats-core` | `nats:2-alpine` | Pub/sub messaging |
| `fluxer-nats-jetstream` | `nats:2-alpine` | Persistent job queue |

Tech stack: Node.js/TypeScript backend, Erlang/OTP WebSocket gateway, React/Rust-WASM frontend, SQLite database.

## Prerequisites

- Docker + Docker Compose
- Traefik reverse proxy with TLS (certresolver or Cloudflare-terminated)
- External `proxy` Docker network
- Two DNS records pointing to your server
- SMTP relay accessible on the `proxy` network (optional, for email)

## Cloudflare DNS and TLS

**TL;DR: Keep Cloudflare proxy enabled (orange cloud) for both `fluxer` and `lk` records.** Do NOT set DNS-only (grey cloud) unless you have your own TLS certificates.

### Why Cloudflare proxy is required

If your Traefik setup relies on Cloudflare for TLS termination (SSL mode "Full" with Cloudflare's edge cert), then switching to DNS-only (grey cloud) will break HTTPS. Clients will receive Traefik's default self-signed certificate, causing browser security errors.

This is the case when `acme.json` contains no certificates and Traefik uses its default cert — Cloudflare's "Full" SSL mode accepts any origin cert (including self-signed), so it works transparently when proxied.

### Cloudflare proxy does NOT cause CSP errors

If you see Content-Security-Policy errors in the browser console, they are **not** caused by Cloudflare proxy. Common CSP errors and their real causes:

| Error | Real Cause | Fix |
|---|---|---|
| `script-src-elem` blocking inline script from `single-file-extension-frames.js` | Browser extension (SingleFile, etc.) | Not a Fluxer issue — disable the extension or ignore |
| `style-src-elem` blocking `fluxerstatic.com/fonts/ibm-plex.css` | Server CSP doesn't include `fluxerstatic.com` | See Gotcha #11 below |
| `img-src` blocking `fluxerstatic.com/web/*.png` | Server CSP doesn't include `fluxerstatic.com` | See Gotcha #11 below |
| `connect-src` blocking `chat.example.com/.well-known/fluxer` | Frontend built with wrong domain | See Gotcha #12 below |

### Cloudflare settings to verify

If you use Cloudflare proxy, ensure these settings in the Cloudflare dashboard:

- **SSL/TLS mode**: Full (not Flexible, not Full Strict)
- **Speed > Optimization > Auto Minify**: Disable JavaScript minification (can break hashed assets)
- **Speed > Optimization > Rocket Loader**: OFF (injects scripts that may conflict with CSP nonces)
- **Scrape Shield > Email Address Obfuscation**: OFF (injects inline scripts)

### LiveKit media transport

Cloudflare proxy handles HTTP/WebSocket signaling for LiveKit (`lk.yourdomain.com`). The actual voice/video media transport (RTP) uses direct UDP/TCP connections on ports 7881, 3478, and 50000-50100, which bypass DNS entirely — clients connect to the server's IP directly via ICE/STUN negotiation. Cloudflare proxy does not interfere with this.

## Step 1: Clone the Source

```bash
mkdir -p /srv/fluxer
cd /srv/fluxer
git clone https://github.com/fluxerapp/fluxer.git
cd fluxer
git checkout refactor  # The self-hosting/monolith branch
```

> **Gotcha: No public Docker image.** The GHCR image at `ghcr.io/fluxerapp/fluxer-server:stable` requires authentication (private registry). You must build from source.

## Step 2: Generate Secrets

Generate hex secrets for all config values:

```bash
# 64-char hex strings (32 bytes)
openssl rand -hex 32  # Repeat for each secret below

# 16-char hex string for LiveKit API key
openssl rand -hex 8
```

Create `/srv/fluxer/.env`:

```env
MEILI_MASTER_KEY=<64-char hex>
FLUXER_SERVER_IMAGE=fluxer-server:local
```

```bash
chmod 600 /srv/fluxer/.env
```

## Step 3: Create Config Files

### `/srv/fluxer/config/config.json`

Key settings to get right:

```jsonc
{
  "env": "production",
  "domain": {
    "base_domain": "fluxer.yourdomain.com",
    "public_scheme": "https",
    "public_port": 443
  },
  "database": {
    "backend": "sqlite",
    "sqlite_path": "/usr/src/app/data/fluxer.db"  // CRITICAL - must be absolute, see Gotcha #14
  },
  "internal": {
    "kv": "redis://fluxer-valkey:6379/0",
    "kv_mode": "standalone"
  },
  "s3": {
    "access_key_id": "fluxer-local",
    "secret_access_key": "fluxer-local-secret",
    "endpoint": "http://127.0.0.1:8080/s3"  // Built-in local S3
  },
  "instance": {
    "self_hosted": true,
    "deployment_mode": "monolith"
  },
  "services": {
    "server": {
      "port": 8080,
      "host": "0.0.0.0",
      "static_dir": "/usr/src/app/assets"  // CRITICAL - see Gotcha #5
    },
    "gateway": {
      "port": 8082
    },
    "nats": {
      "core_url": "nats://fluxer-nats-core:4222",
      "jetstream_url": "nats://fluxer-nats-jetstream:4223",
      "auth_token": ""
    }
    // ... media_proxy, admin, marketing with their secrets
  },
  "integrations": {
    "search": {
      "engine": "meilisearch",
      "url": "http://fluxer-meilisearch:7700",
      "api_key": "<MEILI_MASTER_KEY>"
    },
    "voice": {
      "enabled": true,
      "api_key": "<LIVEKIT_API_KEY>",
      "api_secret": "<LIVEKIT_API_SECRET>",
      "url": "wss://lk.yourdomain.com",
      "webhook_url": "http://fluxer-server:8080/api/webhooks/livekit"
    }
  }
}
```

```bash
chmod 600 /srv/fluxer/config/config.json
```

### `/srv/fluxer/config/livekit.yaml`

```yaml
port: 7880

keys:
  '<LIVEKIT_API_KEY>': '<LIVEKIT_API_SECRET>'

rtc:
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 50100
  use_external_ip: true

turn:
  enabled: true
  udp_port: 3478

room:
  auto_create: true
  max_participants: 100
  empty_timeout: 300

webhook:
  api_key: '<LIVEKIT_API_KEY>'   # CRITICAL - see Gotcha #6
  urls:
    - "http://fluxer-server:8080/api/webhooks/livekit"
```

## Step 4: Fix the Dockerfile

The upstream `fluxer_server/Dockerfile` requires several modifications to build successfully. Apply these changes in the source repo before building:

### 4a. Update package list in Dockerfile

The `deps` stage COPY list must match the actual packages in the monorepo. The upstream Dockerfile may reference `packages/app/` which doesn't exist, and may be missing newer packages.

Compare `ls packages/` with the COPY lines and update accordingly. At time of writing, there are ~47 packages.

### 4b. Add Rust/WASM toolchain to app-build stage

The `fluxer_app` frontend requires Rust + wasm-pack for WebAssembly compilation. Add to the `app-build` stage:

```dockerfile
FROM deps AS app-build

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.93.0 --target wasm32-unknown-unknown
ENV PATH="/root/.cargo/bin:${PATH}"
RUN cargo install wasm-pack
```

> **Gotcha #1: Missing `ca-certificates`.** The slim Debian base image doesn't include CA certificates. Without it, `curl` to download rustup fails with SSL errors.

### 4c. Fix `.dockerignore` exclusions

The `.dockerignore` excludes files needed for the build:

```dockerignore
# Comment out or remove these lines:
# /fluxer_app/src/data/emojis.json
# /fluxer_app/src/locales/*/messages.js

# Add exceptions for build scripts (the **/build pattern catches them):
!fluxer_app/scripts/build
!fluxer_app/scripts/build/**
```

> **Gotcha #2: `.dockerignore` `**/build` pattern.** This glob catches `fluxer_app/scripts/build/rspack/lingui.mjs` which is needed at build time. The exclusion of locale files and emojis.json also breaks TypeScript compilation.

### 4d. Add build config, domain, and Lingui compilation

The frontend build needs `FLUXER_CONFIG` set (rspack reads it to derive API endpoints) and Lingui locale compilation. The `BASE_DOMAIN` build arg patches the template's placeholder domain (`chat.example.com`) with your actual domain:

```dockerfile
COPY config/config.production.template.json /tmp/fluxer-build-config.json

ARG BASE_DOMAIN="chat.example.com"
RUN sed -i "s/chat\.example\.com/${BASE_DOMAIN}/g" /tmp/fluxer-build-config.json

ARG FLUXER_CDN_ENDPOINT=""
ENV FLUXER_CONFIG=/tmp/fluxer-build-config.json
ENV FLUXER_CDN_ENDPOINT=${FLUXER_CDN_ENDPOINT}
RUN cd fluxer_app && pnpm lingui:compile && pnpm build
```

> **Gotcha #3: `FLUXER_CONFIG must be set`.** The rspack config imports the Fluxer config to derive API endpoint URLs for the frontend bundle. Without it, the build crashes immediately.

### 4e. Fix CDN endpoint for self-hosting

In `fluxer_app/rspack.config.mjs`, the CDN endpoint defaults to `https://fluxerstatic.com`:

```javascript
// BEFORE (broken for self-hosting):
const CDN_ENDPOINT = process.env.FLUXER_CDN_ENDPOINT || 'https://fluxerstatic.com';

// AFTER (respects empty string):
const CDN_ENDPOINT = 'FLUXER_CDN_ENDPOINT' in process.env ? process.env.FLUXER_CDN_ENDPOINT : 'https://fluxerstatic.com';
```

> **Gotcha #4: JavaScript `||` treats empty string as falsy.** Setting `FLUXER_CDN_ENDPOINT=""` still falls through to the CDN URL. Must use `in` operator or `??` with explicit `undefined` check. Without this fix, all JS/CSS bundles point to `fluxerstatic.com` instead of being served locally.

### 4f. Fix ENTRYPOINT

```dockerfile
# BEFORE (broken - root workspace has no start script):
ENTRYPOINT ["pnpm", "start"]

# AFTER:
ENTRYPOINT ["pnpm", "--filter", "fluxer_server", "start"]
```

### 4g. Fix CSP for external font/icon CDN

The HTML template (`fluxer_app/index.html`) has hardcoded references to `fluxerstatic.com` for IBM Plex fonts, favicon, and apple-touch-icon. However, the monolith server's Content-Security-Policy only allows `'self'`, blocking these external resources.

In `fluxer_server/src/ServiceInitializer.tsx`, find the `cspDirectives` object in `createAppServerInitializer` and add `https://fluxerstatic.com` to `styleSrc`, `imgSrc`, and `fontSrc`:

```typescript
cspDirectives: {
    // ...
    styleSrc: ["'self'", "'unsafe-inline'", 'https://fluxerstatic.com'],
    imgSrc: ["'self'", 'data:', 'blob:', publicUrlHost, mediaUrlHost, 'https://fluxerstatic.com'],
    fontSrc: ["'self'", 'https://fluxerstatic.com'],
    // ...
},
```

> **Gotcha #11: Monolith CSP blocks `fluxerstatic.com`.** The HTML template loads IBM Plex fonts and favicon from the public `fluxerstatic.com` CDN, but the monolith server's CSP only allows `'self'`. Without this fix, fonts don't load and the browser console shows CSP violation errors for styles, images, and fonts.

## Step 5: Build the Image

```bash
cd /srv/fluxer/fluxer
docker build \
  -t fluxer-server:local \
  --build-arg BASE_DOMAIN="fluxer.yourdomain.com" \
  --build-arg FLUXER_CDN_ENDPOINT="" \
  --build-arg INCLUDE_NSFW_ML=true \
  -f fluxer_server/Dockerfile .
```

Build takes ~20-30 minutes on first run (downloads Rust toolchain, compiles WASM, builds Erlang gateway). Subsequent builds with cached layers are much faster.

- `BASE_DOMAIN` — your Fluxer domain. Baked into the frontend JS for API endpoint discovery. **Must match `domain.base_domain` in config.json.**
- `FLUXER_CDN_ENDPOINT=""` — empty string for self-hosting (assets served from same origin). Without this, all JS/CSS loads from `fluxerstatic.com`.
- `INCLUDE_NSFW_ML=true` — copies the ONNX model for NSFW image detection into the image.

## Step 6: Create docker-compose.yml

Key points for the compose file:

- `fluxer-server` needs `depends_on` with health checks for `fluxer-valkey` and `fluxer-meilisearch`
- Config mounted read-only: `./config:/usr/src/app/config:ro`
- Data volume for SQLite + file storage: `fluxer-data:/usr/src/app/data`
- LiveKit needs host ports: `7881:7881/tcp`, `3478:3478/udp`, `50000-50100:50000-50100/udp`
- Both `fluxer-server` and `fluxer-livekit` need Traefik labels on the `proxy` network
- All internal services on a private `fluxer-internal` network

> **Gotcha #5: `static_dir` must be in config.json, not just an env var.** The server reads `Config.services.server.static_dir` from the JSON config file, not from `FLUXER_SERVER_STATIC_DIR` env var. Without it, the health check shows `app: disabled` and the SPA doesn't serve.

> **Gotcha #6: LiveKit webhook requires `api_key` field.** The `webhook` section in `livekit.yaml` must include `api_key` alongside `urls`. Without it, LiveKit enters a restart loop with `api_key is required to use webhooks`.

> **Gotcha #7: NATS is required, not optional.** The server uses NATS JetStream for its job queue (cron tasks, background processing). Without both `fluxer-nats-core` and `fluxer-nats-jetstream` containers, the server fatally crashes with `CONNECTION_REFUSED` on startup. Deploy both as simple `nats:2-alpine` containers — core on port 4222, JetStream on port 4223 with `--jetstream --store_dir /data`.

## Step 7: Open Firewall Ports

```bash
sudo ufw allow 7881/tcp comment 'Fluxer LiveKit ICE TCP'
sudo ufw allow 3478/udp comment 'Fluxer LiveKit TURN/STUN'
sudo ufw allow 50000:50100/udp comment 'Fluxer LiveKit RTP media'
```

Note: Docker-published ports bypass UFW, but documenting them keeps `ufw status` accurate.

## Step 8: Create DNS Records

Create two Cloudflare A records pointing to your server IP:

| Name | Type | Value | Proxy |
|------|------|-------|-------|
| `fluxer` | A | `<server-ip>` | Proxied (orange cloud) |
| `lk` | A | `<server-ip>` | Proxied (orange cloud) |

**Keep both records Cloudflare-proxied (orange cloud).** See the "Cloudflare DNS and TLS" section above for why DNS-only (grey cloud) breaks HTTPS when Traefik relies on Cloudflare for TLS termination.

LiveKit voice/video media transport (UDP/TCP on ports 7881, 3478, 50000-50100) bypasses DNS entirely — clients connect to the server IP directly via ICE/STUN, so Cloudflare proxy does not interfere.

## Step 9: Deploy

```bash
cd /srv/fluxer
docker compose up -d
```

## Verification

```bash
# All containers running
docker ps --filter "name=fluxer"

# Health check (all services should be "healthy")
curl -s https://fluxer.yourdomain.com/_health | jq

# Web app loads
curl -sI https://fluxer.yourdomain.com/

# LiveKit signaling responds
curl -sI https://lk.yourdomain.com/
```

Expected health response:
```json
{
  "status": "healthy",
  "services": {
    "kv": { "status": "healthy" },
    "s3": { "status": "healthy" },
    "jetstream": { "status": "healthy" },
    "mediaProxy": { "status": "healthy" },
    "admin": { "status": "healthy" },
    "api": { "status": "healthy" },
    "app": { "status": "healthy" }
  }
}
```

Then open `https://fluxer.yourdomain.com` in a browser and register the first user account.

## Summary of Gotchas

| # | Issue | Symptom | Fix |
|---|---|---|---|
| 1 | Missing `ca-certificates` in build | SSL errors downloading rustup | Add `ca-certificates` to `apt-get install` in app-build stage |
| 2 | `.dockerignore` too aggressive | TypeScript errors (missing locales, emojis, build scripts) | Comment out exclusions, add `!fluxer_app/scripts/build` exception |
| 3 | `FLUXER_CONFIG` not set during build | `FLUXER_CONFIG must be set` crash | Copy production template and set env var in Dockerfile |
| 4 | `\|\|` treats `""` as falsy in JS | All assets point to `fluxerstatic.com` CDN | Use `in` operator check in rspack.config.mjs |
| 5 | `static_dir` must be in config JSON | Health shows `app: disabled`, no SPA | Add `"static_dir": "/usr/src/app/assets"` to `services.server` in config.json |
| 6 | LiveKit webhook needs `api_key` | LiveKit restart loop | Add `api_key` field to webhook section in livekit.yaml |
| 7 | NATS is a hard dependency | Fatal `CONNECTION_REFUSED` on startup | Deploy `fluxer-nats-core` and `fluxer-nats-jetstream` containers |
| 8 | Dockerfile package list outdated | Build fails on missing `package.json` files | Update COPY list to match actual packages in monorepo |
| 9 | No `pnpm start` in root workspace | `Missing script: start` | Change ENTRYPOINT to `pnpm --filter fluxer_server start` |
| 10 | GHCR image is private | `pull access denied` | Build from source using the `refactor` branch |
| 11 | Monolith CSP blocks `fluxerstatic.com` | Fonts/icons don't load, CSP violations in console | Add `https://fluxerstatic.com` to `styleSrc`, `imgSrc`, `fontSrc` in ServiceInitializer.tsx |
| 12 | Build config has `chat.example.com` | App tries to connect to wrong domain, `connect-src` CSP error | Pass `--build-arg BASE_DOMAIN=yourdomain` and sed-replace in Dockerfile |
| 13 | Cloudflare DNS-only breaks HTTPS | Browser shows invalid/self-signed cert error | Keep Cloudflare proxy enabled (orange cloud); Traefik has no real certs in acme.json |
| 14 | `sqlite_path` must be absolute | DB created in container filesystem, lost on recreate | Use `"/usr/src/app/data/fluxer.db"` (absolute), not `"./data/fluxer.db"` (relative resolves from `fluxer_server/`) |
| 15 | Admin panel missing `build:css` | `/admin/static/app.css` returns 404, admin panel unstyled | Add `RUN pnpm --filter @fluxer/admin build:css` to Dockerfile after the marketing CSS build |
| 16 | SSO callback not in standalone routes | SSO login loops back to `/login` instead of completing | Add `pathname.startsWith('/auth/sso/')` to `isStandaloneRoute` in RootComponent.tsx |
| 17 | `URLSearchParams` body becomes `"{}"` | OIDC token exchange fails with "grant_type missing" 400 | Add `.toString()` to the `URLSearchParams` in `SsoService.exchangeCode()` |
| 18 | SSO client secret not loaded | Token exchange sends no secret, "empty client secret" 400 | Pass `{includeSecret: true}` to `getSsoConfig()` in `SsoService.getResolvedConfig()` |
| 19 | SSO timeout masks actual error | Real error replaced by "SSO sign-in timed out" after 30s | Add `clearTimeout(timeoutId)` in error/success paths of SsoCallbackPage.tsx |

## SSO (OIDC) Integration

Fluxer supports SSO login via any OIDC provider (e.g., Zitadel, Keycloak). Configuration is done through the admin panel at `/admin` under instance settings — set the issuer URL, client ID, and client secret. The remaining OIDC endpoints (authorization, token, JWKS, userinfo) are auto-discovered from the issuer's `/.well-known/openid-configuration`.

Three source code bugs must be fixed before SSO will work:

### SSO Fix 1: Callback route not in standalone route list (Gotcha #16)

The `RootComponent` maintains a list of routes that render without authentication. The SSO callback path `/auth/sso/callback` is missing, so unauthenticated users returning from the OIDC provider get redirected back to `/login` in an infinite loop.

In `fluxer_app/src/router/components/RootComponent.tsx`, add `/auth/sso/` to the `isStandaloneRoute` check:

```typescript
pathname.startsWith(Routes.CONNECTION_CALLBACK) ||
pathname.startsWith('/auth/sso/') ||       // ADD THIS LINE
pathname === '/__notfound' ||
```

### SSO Fix 2: Token exchange sends empty body (Gotcha #17)

The `SsoService.exchangeCode()` method passes a `URLSearchParams` object as the request body. However, `FetchUtils.resolveRequestBody()` doesn't handle `URLSearchParams` — it falls through to `JSON.stringify()`, which serializes it as `"{}"` (empty object). The OIDC provider receives `Content-Type: application/x-www-form-urlencoded` with an empty body and rejects it with "grant_type missing".

In `packages/api/src/auth/services/SsoService.tsx`, add `.toString()` to convert the `URLSearchParams` to a proper URL-encoded string:

```typescript
const body = new URLSearchParams({
    grant_type: 'authorization_code',
    code,
    redirect_uri: config.redirectUri,
    client_id: config.clientId ?? '',
    code_verifier: codeVerifier,
}).toString();  // ADD .toString() — without it, JSON.stringify produces "{}"
```

### SSO Fix 3: Client secret not loaded for token exchange (Gotcha #18)

The `SsoService.getResolvedConfig()` calls `getSsoConfig()` without `{includeSecret: true}`, so the client secret is always `undefined`. The token exchange sends no Authorization header, and the OIDC provider rejects with "empty client secret".

In `packages/api/src/auth/services/SsoService.tsx`, in `getResolvedConfig()`:

```typescript
// BEFORE:
const stored = await this.instanceConfigRepository.getSsoConfig();

// AFTER:
const stored = await this.instanceConfigRepository.getSsoConfig({includeSecret: true});
```

### SSO Fix 4: Timeout masks actual error message (Gotcha #19)

The `SsoCallbackPage` sets a 30-second timeout, but only clears it in the React cleanup function. If the SSO complete request fails quickly (e.g., 400 error), the catch block shows the real error message, but the still-pending timeout fires 30 seconds later and overwrites it with "SSO sign-in timed out."

In `fluxer_app/src/components/pages/SsoCallbackPage.tsx`, add `clearTimeout(timeoutId)` in all early-return, success, and error paths within the async IIFE.

### SSO Fix 5: SSO users treated as "unclaimed" — all restrictions apply (Gotcha #20)

Fluxer has a concept of "unclaimed" accounts (preview/demo users who haven't set a password). These accounts are restricted: no profile updates, guild invites force-disabled, no messages, no voice, no friend requests, no DMs, no reactions, etc. The check is `User.isUnclaimedAccount()` which returns `passwordHash === null && !isBot`.

**Problem**: SSO users are created with `password_hash: null` (in `SsoService.provisionUserFromClaims()`), so they're incorrectly classified as unclaimed. This blocks ~15 features for SSO users, including profile updates ("Unclaimed Accounts can only set email via token") and guild invite toggling.

**Fix**: In `packages/api/src/models/User.tsx`, update `isUnclaimedAccount()` to exclude SSO users (who get `sso` and `sso:{providerId}` traits at provisioning time):

```typescript
isUnclaimedAccount(): boolean {
    return this.passwordHash === null && !this.isBot && !this._traits.has('sso');
}
```

This single change fixes all unclaimed restrictions across the entire codebase at once, since every check site calls `isUnclaimedAccount()`.

## Admin Panel

### First user gets admin automatically

The first user to register on a fresh Fluxer instance is automatically granted wildcard admin ACLs (`*`). This means the first registered account can access the admin panel at `/admin` with full permissions.

### Granting admin to additional users

If you need to grant admin access to other users after the initial setup, you can do so via SQLite:

```bash
# Find the user's ID
docker exec fluxer-server sqlite3 /usr/src/app/data/fluxer.db \
  "SELECT id, username FROM users WHERE username = 'targetuser';"

# Grant wildcard admin ACL
docker exec fluxer-server sqlite3 /usr/src/app/data/fluxer.db \
  "INSERT INTO admin_acls (user_id, permission) VALUES ('<user-id>', '*');"
```

The admin panel is accessible at `https://fluxer.yourdomain.com/admin`.

## Resource Usage

| Container | RAM | Notes |
|---|---|---|
| fluxer-server | ~300-500MB | Includes Node.js + embedded Erlang gateway |
| fluxer-valkey | ~50-100MB | Grows with cached data |
| fluxer-meilisearch | ~100-200MB | Scales with indexed messages |
| fluxer-livekit | ~50-100MB idle | Scales with active voice sessions |
| fluxer-nats-core | ~20-30MB | Lightweight pub/sub |
| fluxer-nats-jetstream | ~30-50MB | Grows with queue data |
| **Total** | **~550-1000MB** | |
