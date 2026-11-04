# Deployment

## Local

See `README.md`.

## Render or Railway (one web service)

1. Push the project to GitHub.
2. Create a Web Service from the repo.
   - Build: `pip install -r requirements.txt "psycopg[binary]"`
   - Start: `uvicorn app.main:app --host 0.0.0.0 --port $PORT`
   (A `Dockerfile` is also included.)
3. Create a free Supabase project and copy its Postgres connection string. Change the prefix to
   `postgresql+psycopg://` and set it as `DATABASE_URL`.
4. Set environment variables: `JWT_SECRET` (long random), `CALLBACK_SECRET` (long random),
   `CALLBACK_BASE_URL` (your service URL), and the `MPESA_*` values if using Daraja.
5. Open `https://<your-service>/`. HTTPS gives you camera access on phones and the Daraja callback URL.

## Before showing it to anyone outside the team

| Item | Action |
| --- | --- |
| Demo passwords and keys | Set `AUTO_SEED=0`, delete the demo operators, validators and rider, issue new ones |
| `JWT_SECRET` | Must be unique and secret; rotating it signs everyone out |
| Login throttling | Not included. Add rate limiting before public use |
| Backups | Use Supabase backups; the ledger is the record of money |
| Privacy | Register with the ODPC if you process personal data, publish a privacy notice |

## Cold starts

Free hosting tiers sleep when idle. Open the app a few minutes before a demo.
