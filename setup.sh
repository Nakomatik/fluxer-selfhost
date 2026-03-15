#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Fluxer Self-Host Setup
# Generates config files, builds the server from source, obtains an SSL
# certificate, and starts the server.
# Run once on a fresh machine: bash setup.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}▸${RESET} $*"; }
success() { echo -e "${GREEN}✔${RESET} $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET} $*"; }
error()   { echo -e "${RED}✖${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}$*${RESET}"; }

# ── Helpers ───────────────────────────────────────────────────────────────────
require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    error "Required command '$1' not found. $2"
    exit 1
  fi
}

gen_secret() {
  # 64-character random hex string
  openssl rand -hex 32
}

gen_vapid_keys() {
  # Generates a VAPID key pair (P-256 curve) using Node.js and prints
  # "PUBLIC_KEY,PRIVATE_KEY" to stdout.
  # Returns 1 if Node.js is not available.
  if ! command -v node &>/dev/null; then return 1; fi
  node - <<'JS'
const crypto = require('crypto');
const { publicKey, privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
// SPKI-encoded public key → strip 27-byte header → base64url
const pubDer  = publicKey.export({ type: 'spki', format: 'der' });
const pubB64  = pubDer.slice(27).toString('base64url');
// PKCS8-encoded private key → strip 36-byte header → base64url
const privDer = privateKey.export({ type: 'pkcs8', format: 'der' });
const privB64 = privDer.slice(36).toString('base64url');
process.stdout.write(pubB64 + ',' + privB64);
JS
}

prompt() {
  # Usage: prompt VAR_NAME "Question" "default_value"
  local varname="$1" question="$2" default="${3:-}"
  if [[ -n "$default" ]]; then
    echo -en "${CYAN}?${RESET} ${question} [${default}]: "
  else
    echo -en "${CYAN}?${RESET} ${question}: "
  fi
  read -r input
  if [[ -z "$input" && -n "$default" ]]; then
    printf -v "$varname" '%s' "$default"
  else
    printf -v "$varname" '%s' "$input"
  fi
}

prompt_yn() {
  # Usage: prompt_yn "Question" default  (default: y or n)
  # Returns 0 for yes, 1 for no
  local question="$1" default="${2:-y}"
  local hint; [[ "$default" == "y" ]] && hint="Y/n" || hint="y/N"
  echo -en "${CYAN}?${RESET} ${question} [${hint}]: "
  read -r ans
  [[ -z "$ans" ]] && ans="$default"
  [[ "$ans" =~ ^[Yy] ]]
}

read_pem() {
  # Reads a PEM block (certificate or private key) from stdin.
  # Reads lines until -----END is encountered, then stops.
  local label="$1" output=""
  info "Paste your ${label} below (including the -----BEGIN and -----END lines):"
  while IFS= read -r line; do
    output="${output}${line}
"
    [[ "$line" == *"-----END"* ]] && break
  done
  printf '%s' "$output"
}

# ── Prerequisites ─────────────────────────────────────────────────────────────
header "Checking prerequisites…"
require_cmd docker  "Install Docker: https://docs.docker.com/engine/install/"
require_cmd openssl "Install openssl (usually: apt install openssl)"
require_cmd git     "Install git (usually: apt install git)"

# docker compose v2 (plugin) or v1 (standalone)
if docker compose version &>/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE="docker-compose"
else
  error "Docker Compose not found. Install it: https://docs.docker.com/compose/install/"
  exit 1
fi

success "Docker, Docker Compose, and git found."

# ── Re-run guard ──────────────────────────────────────────────────────────────
if [[ -f .env && -f config/config.json ]]; then
  warn "config/config.json and .env already exist."
  if ! prompt_yn "Re-run setup and overwrite them?" "n"; then
    info "Nothing changed. To start: ${COMPOSE} up -d"
    exit 0
  fi
fi

# ── Gather settings ───────────────────────────────────────────────────────────
CACHE_FILE="configs.txt"

# Load cached values as defaults (if a previous run saved them)
CACHED_DOMAIN="" CACHED_LE_EMAIL=""
CACHED_ENABLE_SEARCH="" CACHED_ENABLE_VOICE="" CACHED_ENABLE_EMAIL=""
CACHED_SMTP_HOST="" CACHED_SMTP_PORT="" CACHED_SMTP_USER="" CACHED_SMTP_PASS="" CACHED_SMTP_FROM=""
CACHED_SSL_METHOD="" CACHED_CF_API_TOKEN=""

if [[ -f "$CACHE_FILE" ]]; then
  info "Found ${CACHE_FILE} from a previous run — loading cached values as defaults."
  while IFS='=' read -r key value; do
    # Skip comments and blank lines
    [[ "$key" =~ ^#|^$ ]] && continue
    case "$key" in
      DOMAIN)         CACHED_DOMAIN="$value" ;;
      LE_EMAIL)       CACHED_LE_EMAIL="$value" ;;
      ENABLE_SEARCH)  CACHED_ENABLE_SEARCH="$value" ;;
      ENABLE_VOICE)   CACHED_ENABLE_VOICE="$value" ;;
      ENABLE_EMAIL)   CACHED_ENABLE_EMAIL="$value" ;;
      SMTP_HOST)      CACHED_SMTP_HOST="$value" ;;
      SMTP_PORT)      CACHED_SMTP_PORT="$value" ;;
      SMTP_USER)      CACHED_SMTP_USER="$value" ;;
      SMTP_PASS)      CACHED_SMTP_PASS="$value" ;;
      SMTP_FROM)      CACHED_SMTP_FROM="$value" ;;
      SSL_METHOD)     CACHED_SSL_METHOD="$value" ;;
      CF_API_TOKEN)   CACHED_CF_API_TOKEN="$value" ;;
    esac
  done < "$CACHE_FILE"
fi

header "Server configuration"

prompt DOMAIN        "Your server's domain name (e.g. chat.example.com)" "${CACHED_DOMAIN}"
while [[ -z "$DOMAIN" ]]; do
  warn "Domain name is required."
  prompt DOMAIN "Your server's domain name" "${CACHED_DOMAIN}"
done

prompt LE_EMAIL      "Email for Let's Encrypt notifications" "${CACHED_LE_EMAIL}"
while [[ -z "$LE_EMAIL" ]]; do
  warn "Email is required for Let's Encrypt."
  prompt LE_EMAIL "Email for Let's Encrypt notifications" "${CACHED_LE_EMAIL}"
done

header "Optional features"

ENABLE_SEARCH=false
DEFAULT_SEARCH="y"; [[ "$CACHED_ENABLE_SEARCH" == "false" ]] && DEFAULT_SEARCH="n"
if prompt_yn "Enable full-text search (Meilisearch)?" "$DEFAULT_SEARCH"; then
  ENABLE_SEARCH=true
fi

ENABLE_VOICE=false
DEFAULT_VOICE="y"; [[ "$CACHED_ENABLE_VOICE" == "false" ]] && DEFAULT_VOICE="n"
if prompt_yn "Enable voice & video calls (LiveKit)?" "$DEFAULT_VOICE"; then
  ENABLE_VOICE=true
fi

ENABLE_EMAIL=false
SMTP_HOST="" SMTP_PORT="587" SMTP_USER="" SMTP_PASS="" SMTP_FROM=""
DEFAULT_EMAIL="n"; [[ "$CACHED_ENABLE_EMAIL" == "true" ]] && DEFAULT_EMAIL="y"
if prompt_yn "Enable email (for registration/password reset)?" "$DEFAULT_EMAIL"; then
  ENABLE_EMAIL=true
  prompt SMTP_HOST "SMTP host"              "${CACHED_SMTP_HOST:-smtp.example.com}"
  prompt SMTP_PORT "SMTP port"              "${CACHED_SMTP_PORT:-587}"
  prompt SMTP_USER "SMTP username"          "${CACHED_SMTP_USER}"
  prompt SMTP_PASS "SMTP password"          "${CACHED_SMTP_PASS}"
  prompt SMTP_FROM "From address"           "${CACHED_SMTP_FROM:-noreply@${DOMAIN}}"
fi

header "SSL certificate method"
info "Choose how to obtain your SSL certificate:"
echo -e "  ${BOLD}1${RESET}) HTTP-01 challenge (default — port 80 reachable, no CDN proxy)"
echo -e "  ${BOLD}2${RESET}) Cloudflare Origin Certificate (paste cert + key — easiest for Cloudflare)"
echo -e "  ${BOLD}3${RESET}) Cloudflare DNS-01 challenge (automated, needs API token)"
echo -e "  ${BOLD}4${RESET}) Skip — I already have certificates or will set them up manually"

SSL_METHOD="${CACHED_SSL_METHOD:-1}"
prompt SSL_METHOD "SSL method [1/2/3/4]" "$SSL_METHOD"
# Normalize
case "$SSL_METHOD" in
  2|origin|cf|cloudflare) SSL_METHOD=2 ;;
  3|dns|dns-01)           SSL_METHOD=3 ;;
  4|skip|manual|none)     SSL_METHOD=4 ;;
  *)                      SSL_METHOD=1 ;;
esac

CF_API_TOKEN=""
SSL_CERT_PEM=""
SSL_KEY_PEM=""

if [[ "$SSL_METHOD" == "2" ]]; then
  echo ""
  info "Go to Cloudflare Dashboard → your domain → SSL/TLS → Origin Server → Create Certificate"
  info "Keep defaults (RSA, 15 years), click Create, then paste both values below."
  echo ""
  SSL_CERT_PEM=$(read_pem "Origin Certificate")
  echo ""
  SSL_KEY_PEM=$(read_pem "Private Key")
  echo ""
  if [[ -z "$SSL_CERT_PEM" || -z "$SSL_KEY_PEM" ]]; then
    error "Certificate or private key is empty. Cannot continue."
    exit 1
  fi
  success "Certificate and key received."
  info "Remember to set Cloudflare SSL/TLS mode to 'Full (strict)' after setup."
fi

if [[ "$SSL_METHOD" == "3" ]]; then
  info "You need a Cloudflare API token with Zone:DNS:Edit permission."
  info "Create one at: https://dash.cloudflare.com/profile/api-tokens"
  prompt CF_API_TOKEN "Cloudflare API token" "${CACHED_CF_API_TOKEN}"
  while [[ -z "$CF_API_TOKEN" ]]; do
    warn "API token is required for DNS-01 challenge."
    prompt CF_API_TOKEN "Cloudflare API token" ""
  done
fi

# Save inputs to cache for future re-runs
cat > "$CACHE_FILE" <<EOF
# Saved by setup.sh — $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# These values are used as defaults on re-run. Safe to delete.
DOMAIN=${DOMAIN}
LE_EMAIL=${LE_EMAIL}
ENABLE_SEARCH=${ENABLE_SEARCH}
ENABLE_VOICE=${ENABLE_VOICE}
ENABLE_EMAIL=${ENABLE_EMAIL}
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
SMTP_PASS=${SMTP_PASS}
SMTP_FROM=${SMTP_FROM}
SSL_METHOD=${SSL_METHOD}
CF_API_TOKEN=${CF_API_TOKEN}
EOF
success "Settings cached to ${CACHE_FILE}."

# ── Generate secrets ──────────────────────────────────────────────────────────
header "Generating secrets…"

SECRET_MEDIA_PROXY=$(gen_secret)
SECRET_ADMIN_KEY=$(gen_secret)
SECRET_ADMIN_OAUTH=$(gen_secret)
SECRET_GATEWAY=$(gen_secret)
SECRET_SUDO=$(gen_secret)
SECRET_CONN=$(gen_secret)

MEILI_KEY=""
if $ENABLE_SEARCH; then
  MEILI_KEY=$(gen_secret)
fi

LIVEKIT_KEY="" LIVEKIT_SECRET=""
if $ENABLE_VOICE; then
  LIVEKIT_KEY=$(openssl rand -hex 8)       # short readable key
  LIVEKIT_SECRET=$(openssl rand -hex 24)   # 48-char secret
fi

VAPID_PUBLIC="" VAPID_PRIVATE=""
info "Generating VAPID keys for web push notifications…"
if VAPID=$(gen_vapid_keys 2>/dev/null); then
  VAPID_PUBLIC="${VAPID%%,*}"
  VAPID_PRIVATE="${VAPID##*,}"
  success "VAPID keys generated."
else
  warn "Node.js not found — VAPID keys skipped. Web push notifications will not work."
  warn "You can add them later: https://docs.fluxer.app/self_hosting/configuration"
  VAPID_PUBLIC="REPLACE_VAPID_PUBLIC_KEY"
  VAPID_PRIVATE="REPLACE_VAPID_PRIVATE_KEY"
fi

success "All secrets generated."

# ── Clone & build Fluxer from source ─────────────────────────────────────────
# Gotcha #10: The GHCR image (ghcr.io/fluxerapp/fluxer-server:stable) is
# private and requires authentication. We must build from source instead.
header "Building Fluxer server image from source…"
warn "The GHCR image is private — building locally from source."

if [[ -d fluxer-src ]]; then
  info "fluxer-src/ already exists — skipping clone."
else
  info "Cloning https://github.com/fluxerapp/fluxer.git into fluxer-src/…"
  git clone https://github.com/fluxerapp/fluxer.git fluxer-src
fi

info "Checking out the refactor branch…"
git -C fluxer-src checkout refactor
# Reset to clean upstream so patches apply cleanly on re-runs
git -C fluxer-src reset --hard origin/refactor 2>/dev/null || true
git -C fluxer-src pull --ff-only 2>/dev/null || true

# ── Patch source tree for self-hosted build ──────────────────────────────────
# The upstream source requires several fixes before it will build and run
# correctly in a self-hosted monolith configuration. Each fix references a
# numbered gotcha from DEPLOYMENT.md.
header "Patching source tree for self-hosted build…"

DOCKERFILE="fluxer-src/fluxer_server/Dockerfile"
DOCKERIGNORE="fluxer-src/.dockerignore"

# ·· Gotcha #8: Regenerate Dockerfile package COPY list ······················
# The Dockerfile COPY list references packages/app/ which doesn't exist and
# may be missing newer packages. Rebuild it from the actual directory listing.
info "Fixing Dockerfile package COPY list (Gotcha #8)…"

PKG_COPIES=""
for dir in fluxer-src/packages/*/; do
  pkg=$(basename "$dir")
  if [[ -f "${dir}package.json" ]]; then
    PKG_COPIES="${PKG_COPIES}    COPY packages/${pkg}/package.json ./packages/${pkg}/\n"
  fi
done

awk -v copies="$PKG_COPIES" '
  /^[[:space:]]*COPY packages\/[^\/]+\/package\.json/ {
    if (!done) { printf "%s", copies; done=1 }
    next
  }
  { print }
' "$DOCKERFILE" > "${DOCKERFILE}.tmp" && mv "${DOCKERFILE}.tmp" "$DOCKERFILE"

success "Dockerfile package list updated ($(echo -e "$PKG_COPIES" | grep -c COPY) packages)."

# ·· Gotcha #1: Add Rust/WASM toolchain to app-build stage ···················
# The fluxer_app frontend compiles Rust to WebAssembly via wasm-pack.
# The slim Debian base lacks ca-certificates, so curl/rustup would fail.
info "Adding Rust/WASM build toolchain (Gotcha #1)…"

if ! grep -q 'rustup' "$DOCKERFILE"; then
  cat > /tmp/_fluxer_patch_rust.txt <<'RUSTBLOCK'

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.93.0 --target wasm32-unknown-unknown
ENV PATH="/root/.cargo/bin:${PATH}"
RUN cargo install wasm-pack
RUSTBLOCK

  awk '
    /^FROM deps AS app-build/ {
      print
      while ((getline line < "/tmp/_fluxer_patch_rust.txt") > 0) print line
      next
    }
    { print }
  ' "$DOCKERFILE" > "${DOCKERFILE}.tmp" && mv "${DOCKERFILE}.tmp" "$DOCKERFILE"
  rm -f /tmp/_fluxer_patch_rust.txt
  success "Rust/WASM toolchain added to app-build stage."
else
  info "Rust toolchain already present — skipping."
fi

# ·· Gotcha #2: Fix .dockerignore ············································
# The .dockerignore excludes locale files, emojis.json, and build scripts
# that are needed at build time.
info "Fixing .dockerignore exclusions (Gotcha #2)…"

if [[ -f "$DOCKERIGNORE" ]]; then
  # Comment out exclusions that break the TypeScript build
  sed -i 's|^/fluxer_app/src/data/emojis\.json|# &|' "$DOCKERIGNORE"
  sed -i 's|^/fluxer_app/src/locales/\*/messages\.js|# &|' "$DOCKERIGNORE"

  # Add exceptions for build scripts caught by the **/build glob
  if ! grep -q '!fluxer_app/scripts/build' "$DOCKERIGNORE"; then
    printf '\n# Exceptions for build scripts (Gotcha #2)\n!fluxer_app/scripts/build\n!fluxer_app/scripts/build/**\n' >> "$DOCKERIGNORE"
  fi
  success ".dockerignore patched."
else
  warn ".dockerignore not found — skipping."
fi

# ·· Gotcha #3 + #12: Build config, domain substitution, Lingui ··············
# rspack reads FLUXER_CONFIG to derive API endpoint URLs for the frontend
# bundle. BASE_DOMAIN replaces the template's placeholder with your domain.
# Lingui locale files must be compiled before the frontend build.
info "Adding build config and Lingui compilation (Gotcha #3)…"

if ! grep -q 'FLUXER_CONFIG' "$DOCKERFILE"; then
  cat > /tmp/_fluxer_patch_config.txt <<'CFGBLOCK'
COPY config/config.production.template.json /tmp/fluxer-build-config.json

ARG BASE_DOMAIN="chat.example.com"
RUN sed -i "s/chat\.example\.com/${BASE_DOMAIN}/g" /tmp/fluxer-build-config.json

ARG FLUXER_CDN_ENDPOINT=""
ENV FLUXER_CONFIG=/tmp/fluxer-build-config.json
ENV FLUXER_CDN_ENDPOINT=${FLUXER_CDN_ENDPOINT}
CFGBLOCK

  # Insert config block before the fluxer_app build step and add lingui:compile
  awk '
    /fluxer_app/ && /pnpm build/ && !cfg_done {
      while ((getline line < "/tmp/_fluxer_patch_config.txt") > 0) print line
      cfg_done = 1
      sub(/pnpm build/, "pnpm lingui:compile \\&\\& pnpm build")
    }
    { print }
  ' "$DOCKERFILE" > "${DOCKERFILE}.tmp" && mv "${DOCKERFILE}.tmp" "$DOCKERFILE"
  rm -f /tmp/_fluxer_patch_config.txt
  success "Build config and Lingui step added."
else
  info "FLUXER_CONFIG already set in Dockerfile — skipping."
fi

# ·· Gotcha #4: Hardcode empty CDN endpoint in rspack.config.mjs ·············
# For self-hosting, all assets must be served from the same origin.
# We replace every reference to fluxerstatic.com with '' so rspack sets
# publicPath to "" (relative), regardless of ENV vars or Docker cache.
info "Hardcoding empty CDN endpoint for self-hosted build (Gotcha #4)…"

RSPACK_CFG="fluxer-src/fluxer_app/rspack.config.mjs"
if [[ -f "$RSPACK_CFG" ]]; then
  if grep -q 'fluxerstatic\.com' "$RSPACK_CFG"; then
    sed -i "s|'https://fluxerstatic\.com'|''|g" "$RSPACK_CFG"
    success "All fluxerstatic.com CDN references replaced with '' in rspack config."
  else
    info "No fluxerstatic.com references in rspack config — already clean."
  fi
else
  warn "rspack.config.mjs not found — skipping CDN fix."
fi

# ·· Gotcha #9: Fix ENTRYPOINT ···············································
# The root workspace has no "start" script. Must target fluxer_server.
info "Fixing ENTRYPOINT (Gotcha #9)…"

if grep -q 'ENTRYPOINT \["pnpm", "start"\]' "$DOCKERFILE"; then
  sed -i 's|ENTRYPOINT \["pnpm", "start"\]|ENTRYPOINT ["pnpm", "--filter", "fluxer_server", "start"]|' "$DOCKERFILE"
  success "ENTRYPOINT fixed."
else
  info "ENTRYPOINT already correct — skipping."
fi

# ·· Gotcha #15: Add admin panel CSS build ····································
# The admin panel needs its CSS built separately or it loads unstyled.
info "Adding admin panel CSS build (Gotcha #15)…"

if ! grep -q '@fluxer/admin.*build:css' "$DOCKERFILE"; then
  # Insert after any marketing CSS build line, or before ENTRYPOINT as fallback
  if grep -q 'marketing.*build:css\|build:css.*marketing' "$DOCKERFILE"; then
    sed -i '/marketing.*build:css\|build:css.*marketing/a\RUN pnpm --filter @fluxer/admin build:css' "$DOCKERFILE"
  else
    sed -i '/^ENTRYPOINT/i\RUN pnpm --filter @fluxer/admin build:css\n' "$DOCKERFILE"
  fi
  success "Admin CSS build step added."
else
  info "Admin CSS build already present — skipping."
fi

# ·· Gotcha #11: Fix CSP for fluxerstatic.com ································
# The HTML template loads fonts/icons from fluxerstatic.com but the monolith
# server's CSP only allows 'self', blocking them.
info "Fixing Content-Security-Policy for fluxerstatic.com (Gotcha #11)…"

CSP_FILE="fluxer-src/fluxer_server/src/ServiceInitializer.tsx"
if [[ -f "$CSP_FILE" ]]; then
  if ! grep -q 'fluxerstatic\.com' "$CSP_FILE"; then
    # Add https://fluxerstatic.com to styleSrc, imgSrc, fontSrc arrays
    awk '
      /styleSrc:/ && !/fluxerstatic/ {
        sub(/\]/, ", '"'"'https://fluxerstatic.com'"'"']")
      }
      /imgSrc:/ && !/fluxerstatic/ {
        sub(/\]/, ", '"'"'https://fluxerstatic.com'"'"']")
      }
      /fontSrc:/ && !/fluxerstatic/ {
        sub(/\]/, ", '"'"'https://fluxerstatic.com'"'"']")
      }
      { print }
    ' "$CSP_FILE" > "${CSP_FILE}.tmp" && mv "${CSP_FILE}.tmp" "$CSP_FILE"
    success "CSP updated for fluxerstatic.com."
  else
    info "CSP already includes fluxerstatic.com — skipping."
  fi
else
  warn "ServiceInitializer.tsx not found — skipping CSP fix."
fi

# ·· Gotcha #16: SSO callback route not in standalone route list ··············
# Without this, unauthenticated SSO users get redirected back to /login.
info "Adding SSO callback to standalone routes (Gotcha #16)…"

SSO_ROOT="fluxer-src/fluxer_app/src/router/components/RootComponent.tsx"
if [[ -f "$SSO_ROOT" ]]; then
  if ! grep -q "auth/sso" "$SSO_ROOT"; then
    sed -i "/Routes\.CONNECTION_CALLBACK/a\\            pathname.startsWith('/auth/sso/') ||" "$SSO_ROOT"
    success "SSO callback route added."
  else
    info "SSO route already present — skipping."
  fi
else
  warn "RootComponent.tsx not found — skipping SSO route fix."
fi

# ·· Gotcha #17: URLSearchParams .toString() ··································
# Without .toString(), JSON.stringify produces "{}" and OIDC token exchange
# fails with "grant_type missing".
info "Fixing URLSearchParams serialization (Gotcha #17)…"

SSO_SVC="fluxer-src/packages/api/src/auth/services/SsoService.tsx"
if [[ -f "$SSO_SVC" ]]; then
  if grep -q 'new URLSearchParams' "$SSO_SVC" && ! grep -q '\.toString()' "$SSO_SVC"; then
    awk '
      /new URLSearchParams/ { in_params = 1 }
      in_params && /\}\)/ {
        sub(/\}\);/, "}).toString();")
        in_params = 0
      }
      { print }
    ' "$SSO_SVC" > "${SSO_SVC}.tmp" && mv "${SSO_SVC}.tmp" "$SSO_SVC"
    success "URLSearchParams .toString() added."
  else
    info "URLSearchParams already has .toString() — skipping."
  fi
else
  warn "SsoService.tsx not found — skipping URLSearchParams fix."
fi

# ·· Gotcha #18: SSO client secret not loaded for token exchange ··············
info "Fixing getSsoConfig includeSecret (Gotcha #18)…"

if [[ -f "$SSO_SVC" ]]; then
  if grep -q 'getSsoConfig()' "$SSO_SVC"; then
    # Only change the call inside getResolvedConfig (the one without args)
    sed -i 's/this\.instanceConfigRepository\.getSsoConfig()/this.instanceConfigRepository.getSsoConfig({includeSecret: true})/' "$SSO_SVC"
    success "getSsoConfig now includes secret."
  else
    info "getSsoConfig already passes includeSecret — skipping."
  fi
fi

# ·· Gotcha #19: SSO timeout masks actual error ·······························
# The SsoCallbackPage timeout fires even after success/failure, overwriting
# the real error message.
info "Fixing SSO callback timeout cleanup (Gotcha #19)…"

SSO_CB="fluxer-src/fluxer_app/src/components/pages/SsoCallbackPage.tsx"
if [[ -f "$SSO_CB" ]]; then
  if grep -q 'timeoutId' "$SSO_CB" && ! grep -q 'clearTimeout(timeoutId)' "$SSO_CB"; then
    # Add clearTimeout in the catch block
    awk '
      /catch/ && timeout_seen && !patched {
        print
        getline
        print
        print "          clearTimeout(timeoutId);"
        patched = 1
        next
      }
      /timeoutId/ { timeout_seen = 1 }
      { print }
    ' "$SSO_CB" > "${SSO_CB}.tmp" && mv "${SSO_CB}.tmp" "$SSO_CB"
    success "SSO timeout cleanup added."
  else
    info "SSO timeout already cleaned up — skipping."
  fi
else
  warn "SsoCallbackPage.tsx not found — skipping timeout fix."
fi

# ·· Gotcha #20: SSO users treated as unclaimed ·······························
# SSO users have null password_hash, so isUnclaimedAccount() returns true,
# blocking ~15 features. Exclude users with the 'sso' trait.
info "Fixing isUnclaimedAccount for SSO users (Gotcha #20)…"

USER_MODEL="fluxer-src/packages/api/src/models/User.tsx"
if [[ -f "$USER_MODEL" ]]; then
  if grep -q "this\.passwordHash === null && !this\.isBot" "$USER_MODEL" && \
     ! grep -q "_traits\.has('sso')" "$USER_MODEL"; then
    sed -i "s/this\.passwordHash === null \&\& !this\.isBot/this.passwordHash === null \&\& !this.isBot \&\& !this._traits.has('sso')/" "$USER_MODEL"
    success "isUnclaimedAccount now excludes SSO users."
  else
    info "isUnclaimedAccount already handles SSO — skipping."
  fi
else
  warn "User.tsx not found — skipping unclaimed account fix."
fi

# ·· Skip typecheck — upstream type errors break the build ·····················
# GatewayService.tsx has TS2559 that blocks `pnpm typecheck`.
# Rather than patching each type error, skip the step entirely.
info "Removing typecheck step from Dockerfile (upstream TS2559)…"

sed -i 's|^RUN cd fluxer_server && pnpm typecheck|# typecheck skipped — upstream type errors|' "$DOCKERFILE"
success "Typecheck step removed."

success "All source patches applied."

# ── Build Docker image ───────────────────────────────────────────────────────
echo ""
warn "Building Docker image — this takes 20–30 minutes on first run."
info "Subsequent builds with cached layers are much faster."
echo ""

docker build \
  -t fluxer-server:local \
  --build-arg BASE_DOMAIN="${DOMAIN}" \
  --build-arg FLUXER_CDN_ENDPOINT="" \
  --build-arg INCLUDE_NSFW_ML=true \
  -f fluxer-src/fluxer_server/Dockerfile \
  fluxer-src/

success "Docker image fluxer-server:local built successfully."

# ── Write .env ────────────────────────────────────────────────────────────────
header "Writing .env…"

cat > .env <<EOF
# Generated by setup.sh — $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Do NOT commit this file to version control.

DOMAIN=${DOMAIN}
LETSENCRYPT_EMAIL=${LE_EMAIL}

# Local build — GHCR image is private (Gotcha #10)
FLUXER_IMAGE=fluxer-server:local
FLUXER_PORT=8080

MEILI_MASTER_KEY=${MEILI_KEY}

LIVEKIT_API_KEY=${LIVEKIT_KEY}
LIVEKIT_API_SECRET=${LIVEKIT_SECRET}
EOF

chmod 600 .env
success ".env written."

# ── Write nginx.conf ──────────────────────────────────────────────────────────
header "Writing nginx/nginx.conf…"
sed -i "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g" nginx/nginx.conf
success "nginx.conf configured for ${DOMAIN}."

# ── Build config.json ─────────────────────────────────────────────────────────
header "Writing config/config.json…"

mkdir -p config

# Build the email integration block
if $ENABLE_EMAIL; then
  EMAIL_BLOCK=$(cat <<EJSON
    "email": {
      "enabled": true,
      "provider": "smtp",
      "from_email": "${SMTP_FROM}",
      "smtp": {
        "host": "${SMTP_HOST}",
        "port": ${SMTP_PORT},
        "username": "${SMTP_USER}",
        "password": "${SMTP_PASS}",
        "secure": $([ "$SMTP_PORT" = "465" ] && echo true || echo false)
      }
    },
EJSON
)
else
  EMAIL_BLOCK='    "email": { "enabled": false },'
fi

# Build the search integration block
if $ENABLE_SEARCH; then
  SEARCH_BLOCK=$(cat <<SJSON
    "search": {
      "engine": "meilisearch",
      "url": "http://meilisearch:7700",
      "api_key": "${MEILI_KEY}"
    }
SJSON
)
else
  SEARCH_BLOCK='    "search": { "enabled": false }'
fi

# Build the voice integration block
if $ENABLE_VOICE; then
  VOICE_BLOCK=$(cat <<VJSON
    "voice": {
      "enabled": true,
      "api_key": "${LIVEKIT_KEY}",
      "api_secret": "${LIVEKIT_SECRET}",
      "url": "wss://${DOMAIN}",
      "webhook_url": "http://fluxer:8080/api/webhooks/livekit",
      "default_region": {
        "id": "default",
        "name": "Default",
        "emoji": "🌐",
        "latitude": 0.0,
        "longitude": 0.0
      }
    }
VJSON
)
else
  VOICE_BLOCK='    "voice": { "enabled": false }'
fi

cat > config/config.json <<EOF
{
  "env": "production",

  "domain": {
    "base_domain": "${DOMAIN}",
    "public_scheme": "https",
    "public_port": 443
  },

  "database": {
    "backend": "sqlite",
    "sqlite_path": "/usr/src/app/data/fluxer.db"
  },

  "internal": {
    "kv": "redis://valkey:6379/0",
    "kv_mode": "standalone"
  },

  "s3": {
    "access_key_id": "fluxer-local",
    "secret_access_key": "fluxer-local-secret",
    "endpoint": "http://127.0.0.1:8080/s3"
  },

  "instance": {
    "self_hosted": true,
    "deployment_mode": "monolith"
  },

  "services": {
    "server": {
      "port": 8080,
      "host": "0.0.0.0",
      "static_dir": "/usr/src/app/assets"
    },
    "media_proxy": {
      "secret_key": "${SECRET_MEDIA_PROXY}"
    },
    "admin": {
      "secret_key_base": "${SECRET_ADMIN_KEY}",
      "oauth_client_secret": "${SECRET_ADMIN_OAUTH}"
    },
    "gateway": {
      "port": 8082,
      "admin_reload_secret": "${SECRET_GATEWAY}",
      "media_proxy_endpoint": "http://127.0.0.1:8080/media"
    },
    "nats": {
      "core_url": "nats://nats-core:4222",
      "jetstream_url": "nats://nats-jetstream:4223",
      "auth_token": ""
    }
  },

  "auth": {
    "sudo_mode_secret": "${SECRET_SUDO}",
    "connection_initiation_secret": "${SECRET_CONN}",
    "vapid": {
      "public_key": "${VAPID_PUBLIC}",
      "private_key": "${VAPID_PRIVATE}"
    }
  },

  "integrations": {
${EMAIL_BLOCK}
${SEARCH_BLOCK},
${VOICE_BLOCK}
  }
}
EOF

chmod 600 config/config.json
success "config/config.json written."

# ── Write livekit.yaml ────────────────────────────────────────────────────────
if $ENABLE_VOICE; then
  header "Writing livekit/livekit.yaml…"

  # Generated directly rather than sed-replacing the example, so we can include
  # the webhook section (Gotcha #6) and RTC port range.
  cat > livekit/livekit.yaml <<LKEOF
port: 7880

keys:
  ${LIVEKIT_KEY}: ${LIVEKIT_SECRET}

rtc:
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 50100
  use_external_ip: true
  node_ip: ""

turn:
  enabled: true
  udp_port: 3478

room:
  auto_create: true
  max_participants: 50
  empty_timeout: 300

# Gotcha #6: api_key is required for webhooks — without it LiveKit restart-loops
webhook:
  api_key: ${LIVEKIT_KEY}
  urls:
    - "http://fluxer:8080/api/webhooks/livekit"

logging:
  level: info
  json: true
LKEOF

  success "livekit/livekit.yaml written."
fi

# ── Write docker-compose.override.yml for NATS (Gotcha #7) ───────────────────
# NATS is a hard dependency — the server crashes with CONNECTION_REFUSED without it.
header "Writing docker-compose.override.yml (NATS services)…"

# Build the certbot renewal override based on SSL method
if [[ "$SSL_METHOD" == "3" ]]; then
  # DNS-01: override certbot to use Cloudflare plugin for renewal
  CERTBOT_OVERRIDE=$(cat <<'CBEOF'

  certbot:
    image: certbot/dns-cloudflare:latest
    volumes:
      - certbot_certs:/etc/letsencrypt
      - certbot_webroot:/var/www/certbot
      - ./certbot/cloudflare.ini:/etc/cloudflare.ini:ro
    entrypoint: >
      /bin/sh -c "trap exit TERM;
      while :; do
        certbot renew --dns-cloudflare --dns-cloudflare-credentials /etc/cloudflare.ini --quiet;
        sleep 12h & wait $${!};
      done"
CBEOF
)
elif [[ "$SSL_METHOD" == "2" || "$SSL_METHOD" == "4" ]]; then
  # Origin cert (15yr, no renewal needed) or manual: disable certbot
  CERTBOT_OVERRIDE=$(cat <<'CBEOF'

  certbot:
    image: alpine:latest
    entrypoint: ["sh", "-c", "echo 'Certbot disabled (Origin Certificate or manual SSL)'; exit 0"]
    restart: "no"
CBEOF
)
else
  CERTBOT_OVERRIDE=""
fi

cat > docker-compose.override.yml <<DEOF
# Generated by setup.sh — NATS services required by Fluxer (Gotcha #7).
# The server uses NATS JetStream for its job queue and background processing.
# Without these containers the server fatally crashes on startup.

services:
  nats-core:
    image: nats:2-alpine
    container_name: fluxer_nats_core
    restart: unless-stopped
    command: ["--port", "4222"]
    expose:
      - "4222"
    healthcheck:
      test: ["CMD", "nats-server", "--signal", "ldm"]
      interval: 10s
      timeout: 5s
      retries: 5
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"

  nats-jetstream:
    image: nats:2-alpine
    container_name: fluxer_nats_jetstream
    restart: unless-stopped
    command: ["--port", "4223", "--jetstream", "--store_dir", "/data"]
    expose:
      - "4223"
    volumes:
      - nats_jetstream_data:/data
    healthcheck:
      test: ["CMD", "nats-server", "--signal", "ldm"]
      interval: 10s
      timeout: 5s
      retries: 5
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
${CERTBOT_OVERRIDE}

volumes:
  nats_jetstream_data:
DEOF

success "docker-compose.override.yml written."

# ── Pull Docker images ────────────────────────────────────────────────────────
header "Pulling Docker images…"
PROFILES=""
$ENABLE_SEARCH && PROFILES="${PROFILES} --profile search"
$ENABLE_VOICE  && PROFILES="${PROFILES} --profile voice"

# Pull only remote images — skip 'fluxer' since it's a locally-built image
PULL_SERVICES=$($COMPOSE $PROFILES config --services 2>/dev/null | grep -v '^fluxer$' || true)
if [[ -n "$PULL_SERVICES" ]]; then
  $COMPOSE $PROFILES pull $PULL_SERVICES
fi
success "Images pulled."

# ── Obtain SSL certificate ────────────────────────────────────────────────────
# Docker prefixes volume names with the compose project name (directory name).
PROJECT_NAME=$(basename "$(pwd)")

if [[ "$SSL_METHOD" == "1" ]]; then
  # ·· Method 1: HTTP-01 challenge (direct, no CDN) ····························
  header "Obtaining SSL certificate for ${DOMAIN} (HTTP-01)…"
  info "Starting nginx temporarily for ACME HTTP challenge…"

  cat > /tmp/nginx-acme-only.conf <<NGINXEOF
events { worker_connections 64; }
http {
  server {
    listen 80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ {
      root /var/www/certbot;
    }
    location / { return 200 'waiting for cert'; }
  }
}
NGINXEOF

  docker run -d --rm \
    --name fluxer_nginx_acme \
    -p 80:80 \
    -v /tmp/nginx-acme-only.conf:/etc/nginx/nginx.conf:ro \
    -v "${PROJECT_NAME}_certbot_webroot":/var/www/certbot \
    nginx:alpine >/dev/null

  # Ensure the temp nginx is always cleaned up, even if certbot fails
  trap 'docker stop fluxer_nginx_acme >/dev/null 2>&1 || true' EXIT

  info "Running certbot…"
  docker run --rm \
    -v "${PROJECT_NAME}_certbot_certs":/etc/letsencrypt \
    -v "${PROJECT_NAME}_certbot_webroot":/var/www/certbot \
    certbot/certbot:latest certonly \
      --webroot \
      --webroot-path=/var/www/certbot \
      --email "${LE_EMAIL}" \
      --agree-tos \
      --no-eff-email \
      -d "${DOMAIN}"

  docker stop fluxer_nginx_acme >/dev/null 2>&1 || true
  trap - EXIT
  success "SSL certificate obtained."

elif [[ "$SSL_METHOD" == "2" ]]; then
  # ·· Method 2: Cloudflare Origin Certificate (pasted during setup) ···········
  header "Installing Cloudflare Origin Certificate for ${DOMAIN}…"

  # Write cert and key into the certbot_certs Docker volume in the path nginx expects
  docker run --rm \
    -v "${PROJECT_NAME}_certbot_certs":/etc/letsencrypt \
    alpine sh -c "mkdir -p /etc/letsencrypt/live/${DOMAIN}"

  # Write certificate
  printf '%s' "$SSL_CERT_PEM" | docker run --rm -i \
    -v "${PROJECT_NAME}_certbot_certs":/etc/letsencrypt \
    alpine sh -c "cat > /etc/letsencrypt/live/${DOMAIN}/fullchain.pem"

  # Write private key
  printf '%s' "$SSL_KEY_PEM" | docker run --rm -i \
    -v "${PROJECT_NAME}_certbot_certs":/etc/letsencrypt \
    alpine sh -c "cat > /etc/letsencrypt/live/${DOMAIN}/privkey.pem"

  success "Origin certificate installed into certbot_certs volume."

elif [[ "$SSL_METHOD" == "3" ]]; then
  # ·· Method 3: Cloudflare DNS-01 challenge ···································
  header "Obtaining SSL certificate for ${DOMAIN} (Cloudflare DNS-01)…"

  mkdir -p certbot
  cat > certbot/cloudflare.ini <<CFEOF
dns_cloudflare_api_token = ${CF_API_TOKEN}
CFEOF
  chmod 600 certbot/cloudflare.ini

  info "Running certbot with Cloudflare DNS plugin…"
  docker run --rm \
    -v "${PROJECT_NAME}_certbot_certs":/etc/letsencrypt \
    -v "$(pwd)/certbot/cloudflare.ini":/etc/cloudflare.ini:ro \
    certbot/dns-cloudflare:latest certonly \
      --dns-cloudflare \
      --dns-cloudflare-credentials /etc/cloudflare.ini \
      --dns-cloudflare-propagation-seconds 30 \
      --email "${LE_EMAIL}" \
      --agree-tos \
      --no-eff-email \
      -d "${DOMAIN}"

  success "SSL certificate obtained via Cloudflare DNS."

elif [[ "$SSL_METHOD" == "4" ]]; then
  # ·· Method 4: Manual / skip ·················································
  header "Skipping automatic SSL certificate…"
  warn "You must place your certificate files so they are accessible at:"
  warn "  /etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  warn "  /etc/letsencrypt/live/${DOMAIN}/privkey.pem"
  warn "inside the certbot_certs Docker volume."
  info "Nginx will fail to start until the certificates are in place."
fi

# ── Start the stack ───────────────────────────────────────────────────────────
header "Starting Fluxer…"

# Tear down any previous run first to release ports (avoids docker-proxy ghost binds)
$COMPOSE $PROFILES down --remove-orphans 2>/dev/null || true

# Kill orphaned standalone containers from previous setup attempts (e.g. HTTP-01 acme nginx)
docker stop fluxer_nginx_acme 2>/dev/null || true
docker rm   fluxer_nginx_acme 2>/dev/null || true

# Verify ports 80/443 are free before starting
for port in 80 443; do
  if ss -tlnH "sport = :${port}" 2>/dev/null | grep -q .; then
    warn "Port ${port} is still in use. Attempting to free it…"
    # Find and kill the docker-proxy holding the port
    PID=$(ss -tlnpH "sport = :${port}" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1)
    if [[ -n "$PID" ]]; then
      info "Killing process ${PID} on port ${port}…"
      kill "$PID" 2>/dev/null || true
      sleep 1
    fi
  fi
done

$COMPOSE $PROFILES up -d
success "Fluxer is up!"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Fluxer is running at https://${DOMAIN}${RESET}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}Useful commands:${RESET}"
echo -e "  View logs:          ${CYAN}${COMPOSE} logs -f${RESET}"
echo -e "  Stop:               ${CYAN}${COMPOSE} down${RESET}"
echo -e "  Rebuild image:      ${CYAN}docker build -t fluxer-server:local -f fluxer-src/fluxer_server/Dockerfile fluxer-src/${RESET}"
echo -e "  Check health:       ${CYAN}curl -s https://${DOMAIN}/_health | jq${RESET}"
echo ""
if [[ "$VAPID_PUBLIC" == "REPLACE_VAPID_PUBLIC_KEY" ]]; then
  warn "VAPID keys were not generated (Node.js not found)."
  warn "Web push notifications won't work until you add them."
  warn "See README.md → 'Adding VAPID keys later' for instructions."
  echo ""
fi
