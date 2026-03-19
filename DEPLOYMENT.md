# Deployment Reference

Architecture, build gotchas, and configuration reference for self-hosted Fluxer.
The `setup.sh` script handles all of these automatically — this document explains *why*.

## Architecture

| Container | Image | Purpose |
|---|---|---|
| `fluxer` | Built from source | API, Erlang/OTP gateway, media proxy, admin panel, web app |
| `fluxer_nginx` | `nginx:alpine` | Reverse proxy, TLS termination |
| `fluxer_media_proxy` | `caddy:alpine` | Header normalizer for `/media/*` (see [#23](#23--duplicate-content-length-headers)) |
| `fluxer_valkey` | `valkey/valkey:8.0.6-alpine` | Redis-compatible cache/session store |
| `fluxer_certbot` | `certbot/certbot` | SSL certificate renewal |
| `fluxer_nats_core` | `nats:2-alpine` | Pub/sub messaging |
| `fluxer_nats_jetstream` | `nats:2-alpine` | Persistent job queue |
| `fluxer_meilisearch` | `getmeili/meilisearch:v1.14` | Full-text search *(optional, `--profile search`)* |
| `fluxer_livekit` | `livekit/livekit-server:v1.9.11` | Voice/video SFU *(optional, `--profile voice`)* |

Tech stack: Node.js/TypeScript backend, Erlang/OTP WebSocket gateway, React/Rust-WASM frontend, SQLite database.

## Required Ports

| Port | Protocol | Purpose | Through Cloudflare? |
|------|----------|---------|---------------------|
| 80 | TCP | HTTP → HTTPS redirect | Yes |
| 443 | TCP | HTTPS / WSS (app + LiveKit signaling) | Yes |
| 7881 | TCP | WebRTC TCP ICE fallback | No — direct to server IP |
| 3478 | UDP | STUN / TURN | No — direct |
| 5349 | TCP | TURN over TLS | No — direct |
| 50000–50100 | UDP | WebRTC media streams | No — direct |

Ports 80/443 go through Cloudflare. The LiveKit media ports (7881, 3478, 5349, 50000–50100) carry WebRTC traffic directly to the server IP, bypassing Cloudflare entirely.

## Cloudflare Settings

If using Cloudflare proxy (orange cloud):

| Setting | Required value | Why |
|---------|---------------|-----|
| SSL/TLS mode | Full (strict) | Origin Certificate needs strict validation |
| Speed → Auto Minify (JS) | OFF | Breaks hashed asset filenames |
| Speed → Rocket Loader | OFF | Injects scripts that conflict with CSP nonces |
| Scrape Shield → Email Obfuscation | OFF | Injects inline scripts blocked by CSP |

## Gotcha Reference

All issues discovered in the upstream Fluxer source that `setup.sh` patches automatically.

| # | Category | Issue | Fix |
|---|----------|-------|-----|
| 1 | Build | Missing ca-certificates in app-build stage | Add ca-certificates, pkg-config, libssl-dev, rustup, wasm-pack |
| 2 | Build | `.dockerignore` excludes build-time files | Comment out locale/emoji exclusions, add build script exception |
| 3 | Build | `FLUXER_CONFIG` not set during build | Copy production template, set ENV, add `lingui:compile` |
| 4 | Build | CDN defaults to `fluxerstatic.com` | Hardcode `''` in rspack.config.mjs |
| 5 | Config | `static_dir` must be in config.json | Add to `services.server` |
| 6 | LiveKit | Webhook needs `api_key` field | Add to webhook section in livekit.yaml |
| 7 | Runtime | NATS is a hard dependency | Deploy nats-core (4222) and nats-jetstream (4223) |
| 8 | Build | Dockerfile package COPY list outdated | Regenerate from actual `packages/` directory |
| 9 | Build | ENTRYPOINT targets missing start script | Change to `pnpm --filter fluxer_server start` |
| 10 | Registry | GHCR image is private | Build from source (`refactor` branch) |
| 11 | CSP | Monolith CSP blocks `fluxerstatic.com` | Add to styleSrc, imgSrc, fontSrc in ServiceInitializer.tsx |
| 12 | Build | Build config has `chat.example.com` | `BASE_DOMAIN` build arg + sed replacement |
| 15 | Build | Admin panel missing `build:css` step | Add `RUN pnpm --filter @fluxer/admin build:css` |
| 16 | SSO | Callback route not in standalone list | Add `/auth/sso/` to RootComponent.tsx |
| 17 | SSO | `URLSearchParams` body becomes `"{}"` | Add `.toString()` |
| 18 | SSO | Client secret not loaded for token exchange | Pass `{includeSecret: true}` to `getSsoConfig()` |
| 19 | SSO | Timeout masks actual error | Add `clearTimeout` in error paths |
| 20 | SSO | SSO users treated as unclaimed | Exclude users with `sso` trait |
| 21 | Runtime | BlueskyOAuthService crashes on startup | Short-circuit `create()` — no signing keys for self-host |
| 22 | Build | wasm-opt crashes with SIGSEGV | Disable in Cargo.toml |
| 23 | Runtime | Duplicate Content-Length headers → nginx 502 | Caddy sidecar normalizes headers |
| 24 | Build | moxcms 0.8.1 const-eval crash on wasm32 | Downgrade to 0.8.0 or 0.7.11 |
| 31 | Gateway | `guild_client:do_call` crashes on bare `ok` | Add `ok` clause to `try...of` |

## Gotcha Details

### Dockerfile & Build

#### #1 — Missing ca-certificates
The `app-build` stage uses slim Debian which lacks CA certs. `curl`/rustup fail with SSL errors. Fix: install `ca-certificates`, `pkg-config`, `libssl-dev`, then rustup + wasm-pack.

#### #2 — .dockerignore too aggressive
The `**/build` glob catches `fluxer_app/scripts/build/`. Locale files (`messages.js`) and `emojis.json` are also excluded but needed at build time.

#### #3 — FLUXER_CONFIG required at build time
rspack reads the Fluxer config to derive API endpoint URLs for the frontend bundle. Without `FLUXER_CONFIG` set, the build crashes immediately. The production template is copied in and `chat.example.com` is replaced with the actual domain via `BASE_DOMAIN` build arg.

#### #4 — CDN endpoint fallback
```js
// JS || treats "" as falsy — falls through to the CDN URL
const CDN_ENDPOINT = process.env.FLUXER_CDN_ENDPOINT || 'https://fluxerstatic.com';
```
Fix: hardcode `''` directly in `rspack.config.mjs` instead of relying on env vars (Docker BuildKit content-hashes layers, so touching env vars doesn't bust cache reliably).

#### #8 — Package COPY list outdated
The Dockerfile references `packages/app/` which doesn't exist. The COPY list is regenerated dynamically from the actual `packages/` directory contents.

#### #9 — ENTRYPOINT
Root workspace has no `start` script → `Missing script: start`. Fix: `pnpm --filter fluxer_server start`.

#### #12 — Domain baked into frontend
The production config template contains `chat.example.com`. Without replacement, the frontend tries to connect to the wrong domain, causing `connect-src` CSP errors.

#### #15 — Admin CSS
The admin panel needs its CSS built separately (`pnpm --filter @fluxer/admin build:css`) or it loads completely unstyled.

#### #22 — wasm-opt SIGSEGV
wasm-opt segfaults on some platforms (low memory, certain CPUs). Disabled via `wasm-opt = false` in `Cargo.toml`. The WASM binary works fine without optimization.

#### #24 — moxcms const-eval crash
moxcms 0.8.1's `PQ_LUT_TABLE` uses `pxfm::log()` which triggers "scalar size mismatch" on wasm32. Downgraded to 0.8.0 via `cargo update --precise`.

### Configuration & Runtime

#### #5 — static_dir in config.json
Must be set as `"static_dir": "/usr/src/app/assets"` in `services.server`. The server reads this from JSON, not from an env var. Without it, health shows `app: disabled` and the SPA doesn't serve.

#### #6 — LiveKit webhook api_key
The `webhook` section in `livekit.yaml` must include `api_key` alongside `urls`. Without it, LiveKit enters a restart loop.

#### #7 — NATS required
The server uses NATS JetStream for its job queue and background processing. Without both `nats-core` and `nats-jetstream` containers, the server crashes with `CONNECTION_REFUSED` on startup.

#### #10 — GHCR image private
`ghcr.io/fluxerapp/fluxer-server:stable` requires authentication. Must build from the `refactor` branch.

#### #11 — CSP blocks fluxerstatic.com
The HTML template loads IBM Plex fonts and favicon from `fluxerstatic.com`, but the monolith CSP only allows `'self'`. Fix: add `https://fluxerstatic.com` to `styleSrc`, `imgSrc`, `fontSrc` in `ServiceInitializer.tsx`.

#### #21 — BlueskyOAuthService crashes
Requires JWK signing keys for `private_key_jwt` auth. Self-hosted instances don't have these → constructor throws → `/.well-known/fluxer` returns 500 → entire app unusable. Fix: short-circuit `create()` to return null.

#### #23 — Duplicate Content-Length headers
The server sends both `content-length` (from Hono's Node.js adapter) and `Content-Length` (from app code). nginx strictly rejects duplicate Content-Length per HTTP spec → 502 on all `/media/*` requests. Images appear blurry (only thumbnails work) and stickers don't load.

Fix: Caddy sidecar container (`media-proxy`) sits between nginx and fluxer for `/media/*` requests. Go's HTTP parser consolidates same-value duplicate headers, normalizing them before nginx sees them.

#### #31 — Guild voice state crash
`guild_client:do_call/3` in the Erlang gateway has a `try...of` that only matches map responses and `{error,...}` tuples. The gen_server handler for guild voice state updates returns bare `ok`, which matches neither → `{try_clause, ok}` crash. DMs and group calls work because they bypass the `guild_client` code path. Fix: add an `ok -> {ok, #{success => true}}` clause.

### SSO (OIDC)

Fluxer supports SSO via any OIDC provider (Zitadel, Keycloak, etc.). Configuration is in the admin panel under instance settings. Four bugs must be fixed:

#### #16 — Callback route missing
`/auth/sso/callback` is not in `RootComponent.tsx`'s standalone route list → unauthenticated users returning from the OIDC provider loop back to `/login`.

#### #17 — URLSearchParams serialization
`JSON.stringify(new URLSearchParams({...}))` produces `"{}"`. The OIDC token exchange receives an empty body → "grant_type missing" 400 error. Fix: `.toString()`.

#### #18 — Client secret not loaded
`getSsoConfig()` is called without `{includeSecret: true}` → client secret is always `undefined` → "empty client secret" 400 error.

#### #19 — Timeout overwrites error
`SsoCallbackPage` sets a 30s timeout. If the request fails quickly, the real error shows briefly, then gets overwritten by "SSO sign-in timed out." Fix: `clearTimeout(timeoutId)` in error/success paths.

#### #20 — SSO users classified as unclaimed
SSO users have `password_hash: null` → `isUnclaimedAccount()` returns true → ~15 features blocked (profile updates, guild invites, messages, voice, friend requests, DMs, reactions, etc.). Fix: add `&& !this._traits.has('sso')` to the check.

### LiveKit & Networking

**TURN requires domain + TLS certs** — LiveKit's TURN server needs `domain`, `cert_file`, and `key_file` configured. Without them, LiveKit crash-loops with "TURN domain required" or "TURN tls cert required". The certbot_certs volume is mounted into the livekit container for certificate access.

**Container DNS resolution** — The livekit container can't reach the host's systemd-resolved (`127.0.0.53`). Fix: explicit `dns: [8.8.8.8, 1.1.1.1]` in docker-compose.yml.

**nginx DNS caching (#30)** — nginx resolves `proxy_pass` hostnames at startup. If livekit starts after nginx (or restarts), the cached DNS fails → 502. Fix: use Docker's embedded DNS resolver (`127.0.0.11`) with a variable-based `proxy_pass` for deferred resolution.

**ICE candidates use Docker bridge IP (#25)** — Inside Docker, `use_external_ip` discovers the bridge IP, not the public IP. Fix: auto-detect public IP via `ifconfig.me` and set `node_ip` explicitly. `use_external_ip` is set to `false` since the IP is hardcoded.

## Resource Usage

| Container | RAM (typical) |
|---|---|
| fluxer | ~300–500 MB |
| fluxer_valkey | ~50–100 MB |
| fluxer_meilisearch | ~100–200 MB |
| fluxer_livekit | ~50–100 MB idle |
| fluxer_nats_core | ~20–30 MB |
| fluxer_nats_jetstream | ~30–50 MB |
| **Total** | **~550 MB – 1 GB** |

Build requires ~3–4 GB RAM. On servers with ≤4 GB, create swap before building:
```bash
fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
```
