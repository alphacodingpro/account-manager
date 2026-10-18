import assert from "node:assert/strict";
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

const db = new PGlite();
await db.exec("create table public.companies(id uuid primary key default gen_random_uuid(), name text not null);");
await db.exec(readFileSync(new URL("../supabase/migrations/0057_company_letterhead.sql", import.meta.url), "utf8"));
const { rows: [{ id }] } = await db.query("insert into public.companies(name) values('UltraNet Security') returning id");
const update = (patch) => db.query("update public.companies set address=coalesce($2,address),phone=coalesce($3,phone),logo_data_url=coalesce($4,logo_data_url) where id=$1", [id, patch.address ?? null, patch.phone ?? null, patch.logo ?? null]);
await update({ address: "Karachi, Pakistan", phone: "0311 1074690", logo: "data:image/png;base64,iVBORw0KGgo=" });
await assert.rejects(update({ logo: "data:image/svg+xml;base64,PHN2Zz4=" }), /companies_logo_format/);
await assert.rejects(update({ logo: "https://example.com/logo.png" }), /companies_logo_format/);
await assert.rejects(update({ logo: "data:image/png;base64," + "A".repeat(400100) }), /companies_logo_format/);
await assert.rejects(update({ address: "x".repeat(301) }), /companies_letterhead_lengths/);
console.log("Company letterhead migration checks passed.");
