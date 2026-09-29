# Readyio

| Folder | Production URL | What it is |
| --- | --- | --- |
| [`readyiosite/`](readyiosite/README.md) | https://readyio.com | Marketing site + blog listing (Next.js 16) |
| [`readyiosite-blog/`](readyiosite-blog/README.md) | https://blog.readyio.com | Blog articles (Next.js 16) |
| [`admin-panel/`](admin-panel/README.md) | https://blogpanel.readyio.com | Blog admin panel (React + Vite, static) |
| [`Backend/`](Backend/README.md) | https://api.readyio.com | CMS API + contact/booking/chatbot/newsletter (Express + MySQL) |
| [`deploy/`](deploy/DEPLOYMENT.md) | — | PM2, Nginx and deploy script for the VPS |
| `Frontend/` | not deployed | Old TanStack site, kept as the source of the original blog images |

**Deploying to production:** follow [`deploy/DEPLOYMENT.md`](deploy/DEPLOYMENT.md).

## Run everything locally

```bash
# 1. API (port 4000)
cd Backend && npm install && cp .env.example .env   # fill in .env
npm run migrate && npm run dev

# 2. Main site (port 8080)
cd readyiosite && npm install && npm run dev

# 3. Blog (port 8081)
cd readyiosite-blog && npm install && npm run dev

# 4. Admin panel (port 5173)
cd admin-panel && npm install && npm run dev
```

Both Next.js apps need a `.env.local` with the same `REVALIDATE_SECRET` as `Backend/.env`.
