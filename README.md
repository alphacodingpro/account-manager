# CloudLedger PK

CloudLedger PK is a Pakistan-focused, multi-company cloud accounting platform. This repository contains the Phase 1 foundation: a responsive React PWA, a NestJS API, and a Supabase/PostgreSQL schema with tenant isolation.

## Current foundation

- Supabase email/password authentication
- Multi-company and multi-branch data model
- Owner/accountant/custom-role membership model
- Double-entry journal schema and posting validation
- Company dashboard shell with responsive navigation
- Pakistan-ready company settings (PKR, NTN, STRN, GST registration)
- Row Level Security policies and immutable posted journal entries
- Render deployment blueprint

## Local setup

1. Install Node.js 20+ and run `npm install`.
2. Copy `apps/web/.env.example` to `apps/web/.env` and add Supabase values.
3. Copy `apps/api/.env.example` to `apps/api/.env` and add server values.
4. Run `supabase/migrations/0001_initial.sql` in the Supabase SQL editor.
5. Start both apps with `npm run dev`.

Web: `http://localhost:5173`  
API: `http://localhost:3000/api/health`

## Safety

Never commit Supabase service-role keys. The browser only uses the publishable/anon key. Financial posting is enforced through the API and PostgreSQL functions.

## Roadmap

See [docs/ROADMAP.md](docs/ROADMAP.md).

