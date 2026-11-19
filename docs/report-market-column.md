# User Market in reports

The Market column identifies the user's home market, independently of recorded
outlet City and Area. It does not change filters, dates, populations or totals.

The source is `users_report__marketColumn.xlsx`, sheet `users_report`, rows
2–203, supplied on 19 November 2026. Column G is Market; columns B and F are
the exact login and Promoter ID matching keys. All 202 records have Market and
unique keys. The server-only SQL lookup contains these keys and Market values.
Source spelling is preserved, including VANARASI and VARANASI.

Resolution uses exact login, then exact Promoter ID, then the linked organization
profile's Market override/raw value for users absent from the supplied master.
Names and visited outlet locations are never used to infer Market. An unmatched
user without profile Market remains blank. To revise master Market values,
update the lookup through a migration. It returns only user ID and Market,
requires active staff, and respects `can_see_promoter`. Disabled accounts remain
available to historical reports. It does not update any existing account,
organization, sales or spin record. Matching keys are not bundled in public JS.

Market appears in user and daily performance, zero-spin summary, never-spun,
zero-spin activity, spin history (all-time/weekly/monthly, summary/daily), V7,
V8, transactions (bills/spins/SKU), Users, promoter stock, inventory exports,
flagged activity, outlet requests and the Dashboard's promoter drill-down.
The same row values and columns feed CSV and Excel, including multi-sheet files.
Combined State/Outlet/SKU/Prize summaries remain unchanged as agreed.

Local validation: `node --test test/report-markets.test.mjs
test/zero-spin-audience.test.mjs test/zero-spins.mjs
test/user-performance-state-filter.test.mjs test/transaction-report.test.mjs`.
Also run `node --test test/field-user-market-service.test.mjs` for the real Edge
handler with in-memory clients (no network).

## New field users and rollout

Market is visible and required for new Promoter/TSE/MER accounts. Selecting an
existing organizational record pre-fills its Market, which remains editable.
The shared UI/Edge validator rejects blank/non-text values before auth creation.
The database onboarding function also requires Market, stores it on new org
records, and saves an override when linking an existing record with a different
Market. Existing-account editing and other roles are unchanged.

Apply `20261119000100_report_user_markets.sql` and
`20261119000200_require_new_field_user_market.sql`, then deploy `admin-users`
and the web app together. The second migration adds a required input, so older
web clients that omit Market will receive a validation error and must refresh.
Validated in a new local Docker PostgreSQL database restored from schema only,
with synthetic fixtures. Both migrations passed first application and rerun.
Validation covered all 202 login and Promoter-ID matches, login precedence,
profile fallback, disabled history, supervisor scope, denied anonymous/field/
disabled-staff access, RPC grants, unchanged preexisting records, invalid Market
rejection without partial users, and successful new/linked onboarding.
Run `node scripts/validate-report-markets-postgres.mjs` to repeat the checks.
Evidence: `outputs/report-market-postgres-validation.log`.
No production reads, writes or deployments were performed.
