# Deploying CloudLedger PK

CloudLedger PK is a web app (React, hosted as a static site) on a Supabase backend (PostgreSQL, login, storage).
All accounting rules live in the database migrations, so the database must be fully migrated.

## 1. Create the Supabase project
1. Create a project at supabase.com. Note the **Project URL**, the **anon public key** and the **database password**.
2. Authentication settings (Authentication > Providers / URL configuration):
   - Enable **Confirm email** for production.
   - Set **Site URL** to your final app address and add it to **Redirect URLs**.
   - Set a minimum password length of 8 or more.
   - Configure your own **SMTP** server (Supabase's built-in mail is rate limited and for testing only).
3. Do **not** expose the `service_role` key anywhere in the web app.

## 2. Apply every migration
All files in `supabase/migrations` (0001 to the latest) must be applied, in order.

    npm install -g supabase
    supabase login
    supabase link --project-ref <your-project-ref>
    supabase db push --include-all

The GitHub workflow `.github/workflows/supabase-deploy.yml` does the same automatically on every push to `main`.
It needs these repository secrets: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`, `SUPABASE_DB_PASSWORD`.

## 3. Deploy the web app (Render static site or any static host)
Build command: `npm ci && npm run build -w @cloudledger/web`, publish directory: `apps/web/dist`.
Environment variables (build time):

| Variable | Value |
|---|---|
| `VITE_SUPABASE_URL` | your Project URL |
| `VITE_SUPABASE_ANON_KEY` | your anon public key |
| `VITE_DOCUMENT_SCAN_URL` | optional: address of the OCR service (see `services/document-ocr`) |

Add a rewrite rule `/*` to `/index.html` so page refreshes work (already in `render.yaml`).

## 3b. The API service (`apps/api`)
It only exposes a health check today. You do not need to deploy it.

## 4. First run
Open the app, register the first user, and create a company. A standard Pakistan chart of accounts is created.
Then fill **Settings > Company details** (legal name, NTN/STRN, address, phone, logo). This is the letterhead on every PDF.

## 5. Backups
- Turn on Supabase **daily backups** (Pro plan) or Point-in-Time Recovery for production customers.
- Every owner or admin can also download a **full backup** from Settings > Company details > Download backup.
- Test a restore before you rely on it.

## 6. Upgrading
Pull the new code, run `supabase db push`, redeploy the web app. Migrations only add or change; they never drop customer data.
