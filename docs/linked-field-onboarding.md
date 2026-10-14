# Create a linked field user in one form

In **Users → Field team → Create field user**, select Promoter, TSE or MER,
enter the name, login and PIN, then choose **Create linked user**. Employee
code, geography and supervisor are optional. A new organizational record is
created and linked automatically. If the employee was already imported, select
their unlinked active record in the same form instead. Existing employee
geography, assignments and stock are preserved. Stock issuance remains separate.

The field-team list shows the organizational role and whether the profile is
linked. Existing accounts are not automatically relinked. Manual TSE/MER linking
is supported by the previous migration and the organization screen change.

## Release order

1. Apply `supabase/migrations/20261013000100_allow_manual_field_login_links.sql`
   if not yet applied, then `20261014000100_create_linked_field_user.sql` in
   Supabase. These only add/replace functions; they create no accounts.
2. Deploy `supabase/functions/admin-users/index.ts` to the existing `admin-users`
   Edge Function. Keep its existing secrets and JWT verification configuration.
   Do not expose the service-role key in the frontend.
3. Deploy the updated frontend from GitHub through Hostinger, keeping the site's
   existing production Supabase environment variables. A build without those
   variables runs in demo mode and must not replace the live site.
4. Verify an admin can create one agreed test field account, see its Linked
   status, sign in as that account and select an outlet. Do not run test spins
   or create sales during this check.

Old frontends calling the new Edge Function also get a linked PROMOTER record.
If an imported employee already uses the mobile, creation is refused with an
instruction to select that employee, preventing silent duplicates.

## Validation

- Production Vite build.
- `node test/onboarding-edge.mjs`: authorization, routing to the transactional
  RPC, removal of newly created Auth identities on database errors, and cleanup
  failure messages. Uses the installed web Vite/esbuild dependencies.
- `node test/onboarding-db.mjs`: actual Postgres execution using PGlite with
  repository table definitions; all three roles, imported records, duplicate and
  relink prevention, service-only access, and rollback on invalid input.
  Set `PGLITE_MODULE` to an installed PGlite module, or install it in the ignored
  `.cache/onboarding-tests` directory used by the default test path.
- Local demo browser check: create a TSE from the form and verify TSE / Linked
  / Active in the user list. Demo data remains local to that browser.
