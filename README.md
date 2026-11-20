# CAPEX Control Hub — Supabase-connected starter

This is the Vite + React project supplied for CAPEX Control Hub, updated to use Supabase Auth and the existing PostgreSQL schema.

## What is connected in this build

- Supabase email magic-link sign-in.
- Reads the signed-in user's active `profiles` row.
- Reads active hotels in that user's organisation.
- Reads CAPEX requests visible under the existing Row Level Security policies.
- Saves new CAPEX requests as `draft` rows in `public.capex_requests`.
- Uses live request data for the portfolio request totals and hotel exposure.

## Not yet enabled

The current database migration intentionally does not allow browser clients to submit requests, approve requests, create projects, issue purchase orders, approve invoices, record payments, or change user roles. Those actions must be implemented with trusted server-side functions that validate roles, approval thresholds, budgets, PO balances and payment totals. The UI therefore labels approval workflow as pending rather than pretending to approve records.

Department assignment is also not persisted in this first integration pass because the supplied schema uses a `department_id` foreign key and the current application does not yet have a managed department setup flow.

## Configuration

Copy `.env.example` to `.env.local` and set:

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_ANON_KEY` (the Supabase publishable key is suitable for browser use; never use a service-role or secret key here)

In Vercel, set the same variables for Production, Preview and Development, then redeploy.

## Supabase Auth

The application sends a one-time sign-in link with `signInWithOtp`. In Supabase Dashboard, configure Authentication → URL Configuration so the production application domain is an allowed redirect URL. For local development, allow `http://localhost:5173/**` as well.

The signed-in user must already have an active row in `public.profiles`. The current setup uses the profile created for the Group Admin account.

## Local development

```bash
npm install
npm run dev
```

## Production build

```bash
npm run build
```

Do not put a Supabase service-role key in Vite environment variables or any client-side source file.
