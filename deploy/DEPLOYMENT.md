# Zuvigo production deployment

Everything runs on **one Ubuntu VPS** behind Nginx, with PM2 keeping the Node processes alive and Let's Encrypt (Certbot) providing HTTPS.

| Domain | What it serves | Runs as | Local port |
| --- | --- | --- | --- |
| `zuvigo.com` (+ `www` → redirect) | Marketing site + blog listing (`readyiosite`, Next.js) | PM2 `readyio-site` | 8080 |
| `blog.zuvigo.com` | Blog articles, categories, RSS, sitemap (`readyiosite-blog`, Next.js) | PM2 `readyio-blog` | 8081 |
| `cms-api.zuvigo.com` | CMS API + contact / booking / chatbot / newsletter (`Backend`, Express) | PM2 `readyio-api` | 4000 |
| `blogpanel.zuvigo.com` | Blog admin panel (`admin-panel`, static Vite build) | Nginx only | — |
| `readyio.com` (+ subdomains) | Legacy domains → 301 Permanent Redirect to `zuvigo.com` | Nginx 301 redirects | — |

`Frontend/` is the old TanStack site. It is **not deployed**; it is only used as the image source for `npm run seed:legacy-posts`.

---

## 1. Architecture

```
                      Internet (HTTPS 443)
                               │
                        ┌──────┴──────┐
                        │    Nginx    │  TLS (Let's Encrypt), www → apex 301, readyio.com → zuvigo.com 301
                        └──┬──┬──┬──┬─┘
     zuvigo.com ───────────┘  │  │  └────────── blogpanel.zuvigo.com
     → 127.0.0.1:8080         │  │              → /var/www/readyio/admin-panel/dist
                              │  │
     blog.zuvigo.com ─────────┘  └───────────── cms-api.zuvigo.com
     → 127.0.0.1:8081                           → 127.0.0.1:4000
                                                     │
 readyio-site / readyio-blog ── server-side ─────────┤  http://127.0.0.1:4000/api
                                fetches              │
                                                     ├── MySQL (Amazon RDS, SSL)
 readyio-api ── after publish/edit ──► POST          ├── Cloudinary (images)
   127.0.0.1:8080/api/revalidate                     ├── Upstash Redis (cache, optional)
   127.0.0.1:8081/api/revalidate                     ├── Gmail SMTP (chatbot emails)
                                                     └── OpenRouter (chatbot AI, optional)
```

How the pieces talk to each other:

- **Browsers** call `https://cms-api.zuvigo.com` for the contact form, booking, chatbot, newsletter, the blog view counter and the admin panel.
- **The Next.js servers** fetch articles from `http://127.0.0.1:4000/api` (no public round trip). Pages are cached for 5 minutes.
- **On publish/edit/delete** the API calls both sites' `/api/revalidate` on localhost with `REVALIDATE_SECRET`, so changes appear within seconds instead of waiting for the 5-minute cache.
- Blog links on `zuvigo.com/blog` go to `https://blog.zuvigo.com/<slug>`. Old `zuvigo.com/blog/<slug>` URLs permanently redirect (308) there.
- Incoming traffic to `readyio.com` and its subdomains permanently redirects (301) to the corresponding `zuvigo.com` domains.

Files in this folder:

| File | Purpose |
| --- | --- |
| `deploy/ecosystem.config.cjs` | PM2 definitions for the three Node processes |
| `deploy/nginx/*.conf` | One Nginx site per domain (Zuvigo vhosts + Readyio 301 redirects) |
| `deploy/scripts/deploy.sh` | Install, build and (re)start everything in the right order |

---

## 2. Prerequisites

- **VPS**: Ubuntu 22.04 or 24.04, at least **2 vCPU / 4 GB RAM** (a Next.js build peaks around 1.5–2 GB; on 2 GB RAM add swap, see §4).
- **Root / sudo** SSH access.
- **Domain** `zuvigo.com` with access to its DNS settings (plus `readyio.com` DNS for 301 migration redirects).
- **Accounts / credentials** (already used in development):
  - MySQL database (Amazon RDS) and its `global-bundle.pem` CA file
  - Cloudinary (article images)
  - Upstash Redis (optional cache)
  - Gmail account + App Password for SMTP (chatbot confirmations and lead emails)
  - OpenRouter API key (optional; the chatbot falls back to rule-based replies)
- **Node.js 20.19+ or 22.12+** (Vite 7 and Next.js 16 require it; `deploy.sh` refuses older versions).

---

## 3. DNS

Create these records at your DNS provider for **`zuvigo.com`**, all pointing to the VPS public IP (add matching `AAAA` records if the VPS has IPv6):

| Type | Name | Value |
| --- | --- | --- |
| A | `@` (zuvigo.com) | `<VPS IP>` |
| A | `www` | `<VPS IP>` |
| A | `blog` | `<VPS IP>` |
| A | `api` | `<VPS IP>` |
| A | `blogpanel` | `<VPS IP>` |

**For legacy migration:** keep or point the equivalent DNS records for `readyio.com` (`@`, `www`, `blog`, `api`, `blogpanel`) to the same `<VPS IP>` so Nginx can permanently 301-redirect visitors and search engine crawlers to `zuvigo.com`.

Tips:

- If either domain was live somewhere else, lower TTL to 300 ahead of switching.
- Certbot (§7) only succeeds once `dig +short blog.zuvigo.com` etc. return the VPS IP.

---

## 4. Server setup (one time)

SSH in as root (or a sudo user) and run:

```bash
# System packages
sudo apt update && sudo apt upgrade -y
sudo apt install -y nginx git curl ufw certbot python3-certbot-nginx

# Node.js 22 LTS + PM2
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g pm2
node -v   # must be v20.19+ or v22.12+

# Firewall: only SSH + HTTP/HTTPS are public. Ports 4000/8080/8081 stay internal.
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'
sudo ufw enable

# Dedicated user that owns the code and runs PM2
sudo adduser --disabled-password --gecos "" deploy
sudo mkdir -p /var/www/readyio
sudo chown deploy:deploy /var/www/readyio
```

Optional, recommended on 2 GB RAM machines (prevents `next build` running out of memory):

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

**Database access:** in the RDS security group, allow inbound MySQL (3306) **from the VPS IP only**.

### Get the code onto the server

The project must end up at `/var/www/readyio` with this layout:

```
/var/www/readyio/
├── Backend/
├── readyiosite/
├── readyiosite-blog/
├── admin-panel/
└── deploy/
```

**Option A – Git (recommended, makes redeploys one command).** The code lives in five private GitHub repos under `readyiolab`:

| Repo | Cloned into |
| --- | --- |
| `readyiolab/readyio-deploy` | `/var/www/readyio` (this `deploy/` folder + root README) |
| `readyiolab/blogpanel.ready.backend` | `/var/www/readyio/Backend` |
| `readyiolab/readyiosite` | `/var/www/readyio/readyiosite` |
| `readyiolab/readyiosite-blog` | `/var/www/readyio/readyiosite-blog` |
| `readyiolab/blogpanel.readyio.com` | `/var/www/readyio/admin-panel` |

The `.gitignore` files already exclude `node_modules`, builds, `Backend/.env` and every `.env.local`. On the server:

```bash
cd /var/www
git clone git@github.com:readyiolab/readyio-deploy.git readyio
cd readyio
git clone git@github.com:readyiolab/blogpanel.ready.backend.git Backend
git clone git@github.com:readyiolab/readyiosite.git readyiosite
git clone git@github.com:readyiolab/readyiosite-blog.git readyiosite-blog
git clone git@github.com:readyiolab/blogpanel.readyio.com.git admin-panel
```

`deploy.sh` runs `git pull --ff-only` in all five folders on every deploy.

**Option B – Upload from your PC.** From the project folder on your machine (PowerShell with OpenSSH, or WSL), copy the five folders without `node_modules`, `.next` or `dist`, for example with WSL:

```bash
rsync -av --exclude node_modules --exclude .next --exclude dist \
  --exclude '.env' --exclude '.env.local' \
  Backend readyiosite readyiosite-blog admin-panel deploy \
  deploy@<VPS IP>:/var/www/readyio/
```

---

## 5. Environment files and the RDS certificate

Production URLs are **already committed** and need no editing:

| App | File | Key values |
| --- | --- | --- |
| readyiosite | `.env.production` | `NEXT_PUBLIC_API_URL=https://cms-api.zuvigo.com`, `NEXT_PUBLIC_BLOG_URL=https://blog.zuvigo.com`, `CMS_API_URL=http://127.0.0.1:4000/api` |
| readyiosite-blog | `.env.production` | `NEXT_PUBLIC_API_URL=https://cms-api.zuvigo.com`, `NEXT_PUBLIC_CMS_API_URL=https://cms-api.zuvigo.com/api`, `CMS_API_URL=http://127.0.0.1:4000/api` |
| admin-panel | `.env.production` | `VITE_API_BASE_URL=https://cms-api.zuvigo.com/api`, `VITE_BLOG_SITE_URL=https://blog.zuvigo.com` |

> `NEXT_PUBLIC_*` and `VITE_*` values are baked in at **build time**. After changing them, rebuild (rerun `deploy.sh`).

Secrets are **never committed**. Create them on the server as the `deploy` user:

```bash
cd /var/www/readyio

# 1) One shared revalidation secret for all three apps
SECRET=$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")
echo "REVALIDATE_SECRET=$SECRET" > readyiosite/.env.local
echo "REVALIDATE_SECRET=$SECRET" > readyiosite-blog/.env.local
chmod 600 readyiosite/.env.local readyiosite-blog/.env.local

# 2) Backend secrets
cp Backend/.env.example Backend/.env
chmod 600 Backend/.env
nano Backend/.env
```

In `Backend/.env` fill in every value (see comments in `Backend/.env.example`). Required for production:

- `NODE_ENV=production`, `PORT=4000`
- `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASS`, `DB_NAME`
- `JWT_SECRET`: a **new** random value (`node -e "console.log(require('crypto').randomBytes(48).toString('hex'))"`)
- `ADMIN_EMAIL`, `ADMIN_PASSWORD` (a **new** strong password), `ADMIN_USERNAME`
- `SITE_URL=https://zuvigo.com`, `BLOG_SITE_URL=https://blog.zuvigo.com`
- `CLOUDINARY_*`
- `REVALIDATE_SECRET=<same $SECRET as above>` (print it with `cat readyiosite/.env.local`)
- `REVALIDATE_WEBHOOKS=http://127.0.0.1:8080/api/revalidate,http://127.0.0.1:8081/api/revalidate`
- `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM_EMAIL`, `LEAD_NOTIFICATION_EMAIL`
- Optional: `UPSTASH_REDIS_REST_URL`, `UPSTASH_REDIS_REST_TOKEN`, `OPENROUTER_API_KEY`

**RDS certificate:** `Backend/global-bundle.pem` is the public Amazon RDS CA bundle. It is already in the project; if it is missing on the server, download it:

```bash
curl -o Backend/global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
```

When `DB_HOST` contains `rds.amazonaws.com` and the file exists, both database layers connect over SSL automatically.

---

## 6. Database

The API needs the CMS tables (roles, users, categories, articles, …) and the website tables (`tbl_contact_messages`, `tbl_newsletter_subscribers`, `tbl_booking_requests`, `tbl_chatbot_bookings`). All of them are created by one idempotent migration.

**Using the database that was prepared during development** (already migrated, admin created, 6 legacy posts seeded): nothing to do. Optionally run the migration once to reset the admin password to the new `ADMIN_PASSWORD`:

```bash
cd /var/www/readyio/Backend && npm ci --omit=dev && npm run migrate
```

**Using a brand-new empty database:**

```bash
cd /var/www/readyio/Backend
npm ci --omit=dev
npm run migrate            # creates all tables, roles, permissions and the admin user
```

Then import the 6 original blog posts (safe to re-run; existing slugs are skipped):

```bash
npm run seed:legacy-posts
```

Their images were uploaded to Cloudinary (`readyio-blog/legacy-*`) by an earlier run, so the seeder reuses them and does not need the old `Frontend/` folder.

> `npm run migrate` always resets the admin user's password to `ADMIN_PASSWORD`. Don't run it with an old password in `.env`.

---

## 7. Build, start and HTTPS

### 7.1 First deploy

As the `deploy` user:

```bash
cd /var/www/readyio
bash deploy/scripts/deploy.sh
```

The script:

1. checks Node (20.19+ or 22.12+), PM2, `Backend/.env`, both `.env.local` files and the RDS certificate;
2. `git pull` (if the folder is a git checkout; skip with `SKIP_PULL=1`);
3. installs and starts **the API first** and waits for `http://127.0.0.1:4000/health` (the Next.js builds pre-render blog pages from it);
4. builds `readyiosite`, `readyiosite-blog` and `admin-panel`;
5. starts/reloads `readyio-site` and `readyio-blog`, runs `pm2 save`, and prints a local smoke test.

Add `RUN_MIGRATIONS=1` to also run `npm run migrate` before starting the API.

### 7.2 Start PM2 on boot

```bash
pm2 startup systemd -u deploy --hp /home/deploy
# PM2 prints a `sudo env PATH=... pm2 startup ...` command; run it as a sudo user.
pm2 save

# Keep logs from filling the disk
pm2 install pm2-logrotate
```

### 7.3 Nginx

As a sudo user:

```bash
cd /var/www/readyio
sudo cp deploy/nginx/snippets/cloudflare-realip.conf /etc/nginx/snippets/

# 1) Install new primary Zuvigo virtual hosts
for site in zuvigo.com blog.zuvigo.com cms-api.zuvigo.com blogpanel.zuvigo.com; do
  sudo cp deploy/nginx/$site.conf /etc/nginx/sites-available/$site.conf
  sudo ln -sf /etc/nginx/sites-available/$site.conf /etc/nginx/sites-enabled/$site.conf
done

# 2) Install legacy ReadyIO 301 permanent redirect virtual hosts
for site in readyio.com blog.readyio.com api.readyio.com blogpanel.readyio.com; do
  sudo cp deploy/nginx/$site.conf /etc/nginx/sites-available/$site.conf
  sudo ln -sf /etc/nginx/sites-available/$site.conf /etc/nginx/sites-enabled/$site.conf
done

sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

`blogpanel.zuvigo.com.conf` serves `/var/www/readyio/admin-panel/dist`. Edit `root` there if you used another folder. Nginx must be able to read it: `sudo chmod o+x /var/www /var/www/readyio`.

**Cloudflare:** if your DNS is proxied through Cloudflare (orange cloud), every site config includes `snippets/cloudflare-realip.conf`, which restores the visitor's IP from `CF-Connecting-IP`; without it all visitors share Cloudflare's IPs and hit the API rate limits together. In the Cloudflare dashboard set **SSL/TLS → Full (strict)** (Flexible causes redirect loops with the HTTPS redirect) and keep **Rocket Loader off** (it breaks Next.js hydration). Also turn off **Scrape Shield → Email Address Obfuscation**: it injects `email-decode.min.js` into every page, which sits in the render-critical request chain and slows first paint.

### 7.4 HTTPS certificates

```bash
# Request SSL for Zuvigo primary domains:
sudo certbot --nginx --redirect -m you@zuvigo.com --agree-tos \
  -d zuvigo.com -d www.zuvigo.com \
  -d blog.zuvigo.com -d cms-api.zuvigo.com -d blogpanel.zuvigo.com

# Maintain SSL for legacy Readyio domains so HTTPS 301 redirects work without certificate warnings:
sudo certbot --nginx --redirect -m you@zuvigo.com --agree-tos \
  -d readyio.com -d www.readyio.com \
  -d blog.readyio.com -d api.readyio.com -d blogpanel.readyio.com

sudo certbot renew --dry-run    # confirms auto-renewal works
```

Certbot edits the site files to add the 443 listeners and an HTTP→HTTPS redirect. Renewal runs automatically via a systemd timer.

---

## 8. Go-live checklist

Run from your PC after DNS and HTTPS are in place. Replace `<slug>` with a real article slug (for example one from `https://cms-api.zuvigo.com/api/articles`).

```bash
# Main site
curl -sI https://zuvigo.com | head -1                       # HTTP/2 200
curl -sI https://www.zuvigo.com | grep -i location          # https://zuvigo.com/
curl -sI https://zuvigo.com/blog | head -1                  # 200
curl -sI https://zuvigo.com/blog/<slug> | grep -i location  # https://blog.zuvigo.com/<slug>
curl -s  https://zuvigo.com/sitemap.xml | head -5

# 301 Domain Migration Redirects from ReadyIO
curl -sI https://readyio.com | grep -i location             # https://zuvigo.com/
curl -sI https://blog.readyio.com/my-post | grep -i location # https://blog.zuvigo.com/my-post
curl -sI https://api.readyio.com/health | grep -i location  # https://cms-api.zuvigo.com/health
curl -sI https://blogpanel.readyio.com | grep -i location   # https://blogpanel.zuvigo.com/

# Blog
curl -sI https://blog.zuvigo.com | head -1                  # 200
curl -sI https://blog.zuvigo.com/<slug> | head -1           # 200
curl -s  https://blog.zuvigo.com/robots.txt
curl -s  https://blog.zuvigo.com/sitemap.xml | head -5
curl -sI https://blog.zuvigo.com/feed.xml | head -1         # 200

# API
curl -s  https://cms-api.zuvigo.com/health                  # {"status":"Server is running"}
curl -s  "https://cms-api.zuvigo.com/api/articles" | head -c 300
curl -si -X OPTIONS https://cms-api.zuvigo.com/api/contact \
  -H "Origin: https://zuvigo.com" -H "Access-Control-Request-Method: POST" \
  | grep -i access-control-allow-origin                      # https://zuvigo.com

# Admin panel
curl -sI https://blogpanel.zuvigo.com | grep -i x-robots-tag      # noindex, nofollow
curl -sI https://blogpanel.zuvigo.com/articles | head -1          # 200 (SPA fallback)

# Revalidation endpoints are not public
curl -si -X POST https://zuvigo.com/api/revalidate | head -1      # 403
curl -si -X POST https://blog.zuvigo.com/api/revalidate | head -1 # 403
```

In a browser:

- [ ] Log in at `https://blogpanel.zuvigo.com` with the new admin password.
- [ ] Edit an article, save → within a few seconds the change shows on `https://blog.zuvigo.com/<slug>` and on `https://zuvigo.com/blog`.
- [ ] Open an article twice → its view count rises in the admin panel.
- [ ] Submit the contact form on `https://zuvigo.com/contact` → message appears in `tbl_contact_messages`.
- [ ] Subscribe to the newsletter (site footer and blog footer) → subscriber appears in the admin panel **Newsletter** page.
- [ ] Book a call via the chatbot → confirmation and lead emails arrive.
- [ ] No red CSP/CORS errors in the browser console on any of the four domains.

---

## 9. Redeploy, rollback and logs

**Redeploy** after pushing changes:

```bash
sudo -iu deploy
cd /var/www/readyio && bash deploy/scripts/deploy.sh
```

A redeploy rebuilds everything; the sites may answer slowly for a few seconds while the build swaps in.

**Only restart the API** (e.g. after editing `Backend/.env`):

```bash
pm2 reload readyio-api --update-env
```

**Rollback** (Git checkout):

```bash
cd /var/www/readyio
git log --oneline -5                 # find the last good commit
git checkout <good-commit>
SKIP_PULL=1 bash deploy/scripts/deploy.sh
# later, return to the branch: git checkout main && bash deploy/scripts/deploy.sh
```

**Logs and status:**

```bash
pm2 status
pm2 logs readyio-api --lines 100     # API errors, "Revalidation webhook ... failed" warnings
pm2 logs readyio-site
pm2 logs readyio-blog
pm2 monit
sudo tail -f /var/log/nginx/access.log /var/log/nginx/error.log
```

---

## 10. Security (do this before announcing the launch)

The development `.env` files and chat history contained live credentials. Treat them as exposed:

- [ ] **Rotate the database password** (RDS console) and update `DB_PASS`.
- [ ] **Rotate the Cloudinary API secret** and update `CLOUDINARY_API_SECRET`.
- [ ] **Rotate the Upstash token.** The Upstash hostname used in development no longer resolves; create a new database (or remove the two `UPSTASH_*` lines; the API works without cache, just slower).
- [ ] **New `JWT_SECRET`** (signs out every admin session).
- [ ] **New `REVALIDATE_SECRET`**, identical in `Backend/.env`, `readyiosite/.env.local` and `readyiosite-blog/.env.local`.
- [ ] **New admin password**: set `ADMIN_PASSWORD` in `Backend/.env` and run `cd Backend && npm run migrate` (the migration is idempotent and only resets that user's password). Signed-in users can also call `PUT https://api.zuvigo.com/api/auth/change-password`.
- [ ] **Gmail**: use an App Password in `SMTP_PASS`, never the account password.
- [ ] Firewall: only 22/80/443 open (`sudo ufw status`). RDS inbound limited to the VPS IP.
- [ ] `chmod 600` on `Backend/.env` and both `.env.local` files.
- [ ] Optional: `sudo apt install fail2ban unattended-upgrades` and disable SSH password login.

Built-in protections: Helmet headers and CORS allow-list on the API; login rate limit; contact/booking/newsletter limited to 10 requests per 15 minutes per IP and the chatbot to 40 per 5 minutes; CSP and security headers on both Next.js sites; `/api/revalidate` blocked at Nginx and secret-protected; admin panel `noindex`.

---

## 11. Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| `deploy.sh` fails at "waiting for /health" | `pm2 logs readyio-api`. Usually a missing `JWT_SECRET` (the API refuses to start without it) or a bad `.env` value. |
| API logs `ETIMEDOUT` / `ECONNREFUSED` to the database | RDS security group does not allow the VPS IP, or wrong `DB_HOST`/`DB_PORT`. |
| API logs SSL / certificate errors | `Backend/global-bundle.pem` missing or outdated; re-download it (§5). |
| `next build` fails fetching `127.0.0.1:4000` | The API was not running during the build. Run the full `deploy.sh`, which starts the API first. |
| `next build` killed / "JavaScript heap out of memory" | Not enough RAM; add swap (§4). |
| Browser: "blocked by CORS policy" | The calling origin isn't allowed. The API allows both `zuvigo.com` and `readyio.com` origins (`zuvigo.com`, `www.zuvigo.com`, `blog.zuvigo.com`, `blogpanel.zuvigo.com`, `readyio.com`, `www.readyio.com`, `blog.readyio.com`, `blogpanel.readyio.com`); add others to `CORS_ORIGIN` and `pm2 reload readyio-api --update-env`. |
| Site still calls `localhost` / old URLs | `NEXT_PUBLIC_*` / `VITE_*` are build-time values; rebuild with `deploy.sh`. |
| Published changes take ~5 minutes to appear | Revalidation isn't reaching the sites: check `REVALIDATE_SECRET` is identical in all three files and `REVALIDATE_WEBHOOKS` is set, then look for "Revalidation webhook" in `pm2 logs readyio-api`. |
| Admin panel page refresh gives 404 | The Nginx `try_files ... /index.html` fallback is missing; use `deploy/nginx/blogpanel.zuvigo.com.conf`. |
| Admin image upload fails with 413 | Nginx body limit; `api.zuvigo.com.conf` sets `client_max_body_size 12m`. |
| Chatbot emails never arrive | Check `SMTP_*`; many VPS providers block outbound port 587 by default (open a support ticket or use a transactional mail service). |
| Newsletter/contact returns 429 | Rate limit hit (by design). Wait 15 minutes. |
| `certbot` fails | DNS for that subdomain doesn't point at the VPS yet, or port 80 is blocked. |

---

## 12. Search engines (after go-live)

1. In [Google Search Console](https://search.google.com/search-console) add a **Domain property** for `zuvigo.com` (verified with a DNS TXT record; it covers every subdomain).
2. Submit both sitemaps:
   - `https://zuvigo.com/sitemap.xml`
   - `https://blog.zuvigo.com/sitemap.xml`
3. In Search Console for `readyio.com`, use the **Change of Address** tool to signal the domain migration to Google.
4. Use **URL Inspection** on the home page and one article to request indexing.
5. Optional: do the same in [Bing Webmaster Tools](https://www.bing.com/webmasters) (it can import from Search Console).

What is already in place for SEO: canonical URLs, Open Graph/Twitter cards, `BlogPosting`/`BreadcrumbList`/`FAQPage` JSON-LD on articles, RSS at `https://blog.zuvigo.com/feed.xml`, 301 redirects from all old `readyio.com` URLs, and `noindex` on the admin panel.
