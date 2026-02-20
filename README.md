# Fluxer Self-Host

Docker Compose setup for running your own [Fluxer](https://fluxer.app) server — the free and open source Discord alternative.

> **All credit for the Fluxer platform goes to the Fluxer team.**
> This repository only provides the hosting configuration. The Fluxer application and all associated intellectual property belong to the original developers.
> Official project: [github.com/fluxerapp/fluxer](https://github.com/fluxerapp/fluxer) · License: GNU AGPL v3

---

## What you get

| Feature | Included | Notes |
|---------|----------|-------|
| Fluxer server | ✅ | Official `ghcr.io/fluxerapp/fluxer-server:stable` image |
| SQLite database | ✅ | Zero-config, data stored in a Docker volume |
| HTTPS (Let's Encrypt) | ✅ | Auto-obtained and auto-renewed |
| Full-text search | ⚙️ optional | Meilisearch — enable with `--profile search` |
| Voice & video calls | ⚙️ optional | LiveKit — enable with `--profile voice` |
| Email (SMTP) | ⚙️ optional | For registration / password reset |

---

## Requirements

- A Linux server (Ubuntu 22.04+ recommended)
- A domain name pointed at your server's IP (`A` record)
- Docker 24+ and Docker Compose v2
- Ports `80` and `443` open in your firewall
- If enabling voice/video: ports `7881` (TCP), `3478` (UDP), `50000–50100` (UDP) open

---

## Quick start

```bash
# 1. Clone this repo
git clone https://github.com/shadowflee3/fluxer-selfhost
cd fluxer-selfhost

# 2. Run the setup script — it will ask a few questions then do everything
bash setup.sh
```

That's it. The script will:
1. Ask for your domain and email address
2. Ask which optional features to enable
3. Generate all secret keys automatically
4. Write `config/config.json` and `.env`
5. Obtain an SSL certificate via Let's Encrypt
6. Pull all Docker images and start the stack

When it finishes, open `https://your-domain.com` in your browser and create your first account.

---

## Manual setup (step by step)

If you prefer not to use the automated script:

### 1. Configure environment

```bash
cp .env.example .env
nano .env   # set DOMAIN and LETSENCRYPT_EMAIL at minimum
```

### 2. Generate secrets

You need random secret keys for the config. Generate them with:

```bash
openssl rand -hex 32   # run once per secret field
```

### 3. Create config.json

```bash
cp config/config.example.json config/config.json
nano config/config.json
```

Replace every `REPLACE_…` placeholder with a generated secret and set `base_domain` to your domain.

**Required fields:**

| Field | Description |
|-------|-------------|
| `domain.base_domain` | Your domain, e.g. `chat.example.com` |
| `services.media_proxy.secret_key` | 64-char hex secret |
| `services.admin.secret_key_base` | 64-char hex secret |
| `services.admin.oauth_client_secret` | 64-char hex secret |
| `services.gateway.admin_reload_secret` | 64-char hex secret |
| `auth.sudo_mode_secret` | 64-char hex secret |
| `auth.connection_initiation_secret` | 64-char hex secret |
| `auth.vapid.public_key` | VAPID public key (see below) |
| `auth.vapid.private_key` | VAPID private key (see below) |

### 4. Generate VAPID keys

VAPID keys are needed for browser push notifications. If you have Node.js 15+:

```bash
node -e "
const crypto = require('crypto');
const { publicKey, privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
const pub  = publicKey.export({ type: 'spki', format: 'der' }).slice(27).toString('base64url');
const priv = privateKey.export({ type: 'pkcs8', format: 'der' }).slice(36).toString('base64url');
console.log('Public: ', pub);
console.log('Private:', priv);
"
```

### 5. Obtain SSL certificate

```bash
# Start a temporary HTTP server for the ACME challenge
docker run -d --rm --name tmp_nginx -p 80:80 \
  -v $(pwd)/nginx/nginx.conf:/etc/nginx/nginx.conf:ro \
  -v fluxer-selfhost_certbot_webroot:/var/www/certbot \
  nginx:alpine

# Get the certificate
docker run --rm \
  -v fluxer-selfhost_certbot_certs:/etc/letsencrypt \
  -v fluxer-selfhost_certbot_webroot:/var/www/certbot \
  certbot/certbot certonly \
    --webroot --webroot-path=/var/www/certbot \
    --email you@example.com --agree-tos --no-eff-email \
    -d your-domain.com

docker stop tmp_nginx
```

### 6. Start the stack

```bash
docker compose up -d
```

---

## Enabling optional features

### Full-text search (Meilisearch)

1. Set `MEILI_MASTER_KEY` in `.env` to any random secret (`openssl rand -hex 32`)
2. In `config/config.json`, set `integrations.search.api_key` to the same value
3. Start with the search profile:

```bash
docker compose --profile search up -d
```

### Voice & video calls (LiveKit)

1. Open firewall ports: `7881/tcp`, `3478/udp`, `50000-50100/udp`
2. In `.env`, set `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET`
3. Copy and edit the LiveKit config:

```bash
cp livekit/livekit.example.yaml livekit/livekit.yaml
nano livekit/livekit.yaml   # replace REPLACE_… values
```

4. In `config/config.json`, set `integrations.voice.enabled = true` and fill in the key/secret
5. Start with the voice profile:

```bash
docker compose --profile voice up -d
```

### Email (registration, password reset)

In `config/config.json`, update the `integrations.email` block:

```json
"email": {
  "enabled": true,
  "provider": "smtp",
  "from_email": "noreply@your-domain.com",
  "smtp": {
    "host": "smtp.example.com",
    "port": 587,
    "username": "your-smtp-user",
    "password": "your-smtp-password",
    "secure": false
  }
}
```

Then restart: `docker compose restart fluxer`

---

## Updating Fluxer

```bash
docker compose pull
docker compose up -d
```

Watchtower can automate this for you — see the [Watchtower docs](https://containrrr.dev/watchtower/).

---

## Useful commands

```bash
# View live logs
docker compose logs -f

# View logs for one service
docker compose logs -f fluxer

# Stop everything
docker compose down

# Stop and wipe all data (destructive!)
docker compose down -v

# Restart a single service
docker compose restart fluxer

# Check container health
docker compose ps

# Open a shell inside the Fluxer container
docker compose exec fluxer sh

# Manually renew the SSL certificate
docker compose exec certbot certbot renew --force-renewal
```

---

## Backups

The important data lives in two Docker volumes:

| Volume | Contents |
|--------|----------|
| `fluxer_data` | SQLite database + uploaded files |
| `valkey_data` | Cache (can be lost without data loss) |

To back up:

```bash
# Stop Fluxer (recommended for a clean SQLite snapshot)
docker compose stop fluxer

# Export the data volume
# Note: Docker names volumes using the project directory name as a prefix.
# If you cloned into a directory other than "fluxer-selfhost", adjust accordingly.
PROJ=$(basename $(pwd))
docker run --rm \
  -v ${PROJ}_fluxer_data:/data \
  -v $(pwd):/backup \
  alpine tar czf /backup/fluxer-backup-$(date +%Y%m%d).tar.gz -C /data .

# Restart
docker compose start fluxer
```

To restore:

```bash
PROJ=$(basename $(pwd))
docker compose down
docker volume rm ${PROJ}_fluxer_data
docker volume create ${PROJ}_fluxer_data
docker run --rm \
  -v ${PROJ}_fluxer_data:/data \
  -v $(pwd):/backup \
  alpine tar xzf /backup/fluxer-backup-YYYYMMDD.tar.gz -C /data
docker compose up -d
```

---

## Troubleshooting

**Fluxer container won't start**
```bash
docker compose logs fluxer
```
Usually a missing or malformed `config/config.json`.

**SSL certificate errors**
Make sure your domain's DNS `A` record points to this server and ports 80/443 are reachable.

**WebSocket disconnects**
Ensure `proxy_read_timeout 86400s` is in `nginx/nginx.conf` (it is by default).

**Voice calls don't work**
Check that UDP ports `3478` and `50000-50100` are open in your firewall. LiveKit needs direct UDP reachability from clients.

**"Health check failing" for Fluxer**
Give it up to 30 seconds on first start — it runs database migrations on boot.

---

## Project structure

```
fluxer-selfhost/
├── docker-compose.yml          # All services, with optional profiles
├── setup.sh                    # Automated first-run setup
├── .env.example                # Environment variable reference
├── config/
│   ├── config.example.json     # Annotated config template
│   └── config.json             # Your config (generated by setup.sh, gitignored)
├── nginx/
│   └── nginx.conf              # Reverse proxy + HTTPS
└── livekit/
    ├── livekit.example.yaml    # LiveKit config template
    └── livekit.yaml            # Your LiveKit config (generated, gitignored)
```

---

## Credits

- **[Fluxer](https://fluxer.app)** — the application, server, and all platform code
  - GitHub: [github.com/fluxerapp/fluxer](https://github.com/fluxerapp/fluxer)
  - License: GNU AGPL v3
- **This hosting configuration** is maintained by [shadowflee](https://github.com/shadowflee3) and is not affiliated with or endorsed by the official Fluxer project.

---

## License

This configuration repository is released under [MIT](LICENSE). The Fluxer platform itself is licensed under the [GNU Affero General Public License v3](https://www.gnu.org/licenses/agpl-3.0.html).
