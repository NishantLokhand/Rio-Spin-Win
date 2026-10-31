# Requested enrollment — 31 October 2026

Production execution remains pending. Supabase CLI is not authenticated in this workspace.

Run these complete scripts individually in the existing production Supabase SQL Editor, in order:

1. `supabase/migrations/20261031000100_enroll_tushar_amrutkar_special_v7.sql`
2. `supabase/migrations/20261031000200_enroll_ashish_sujal_v8.sql`
3. `supabase/repairs/20261031_verify_requested_v7_v8_users.sql`

Do not apply the entire outstanding migrations directory. No frontend release is required.

Tushar Suresh Amrutkar joins the existing V7 special `no_snack5` category: 100% INR10 without available shades, or the existing 96% INR10 / 4% shades mix with shades. His administrator-reported 75 INR10 units are not issued again. Current stock must be positive; a different positive balance is reported without resetting it. Existing V7 dates and toggle must already be active; no extension is made. Any existing V8 membership is retained.

Ashish Ramu Kalwal and Sujal Kalidas Wankhede are selected for the existing V8 third-daily-spin speaker rule, recording 10 speakers each as reference data only. Their existing ordinary V7/V6 assignments are retained. Positive available speaker stock is required; global V8 settings still determine effective eligibility. Enrollment after the third spin gives no catch-up award that day.

Each account must have exactly one normalized full-name match and be an active linked field user. Ambiguity, missing accounts or unavailable required stock abort the applicable transaction. Scripts retain inventory, functions, counters and history. Reruns preserve later admin membership edits. Private snapshots support exact membership rollback using the two corresponding files in `supabase/rollbacks/`; rollback refuses later membership edits and retains current stock/activity.

Harshraj Shelar is checked read-only, never re-enrolled by these scripts. A separate local enrollment script for 20 speakers exists from 30 October, but its presence does not establish live membership. In the status result, require exactly one account match, `selected_for_v8 = true`, and `v8_effective = true`; review current stock and reservations. A balance below 20 can reflect live awards and must not be replenished automatically.

Validation: `node scripts/validate-oct31-enrollment.mjs` creates an isolated local PostgreSQL database. It exercises 50 real Tushar spin/handover calls from 75 INR10 and zero INR5, five calls per V8 user with a single third-spin speaker and replay, membership/runtime preservation, idempotency, rollback after activity, duplicate and missing identities, fully reserved stock, no repeat speaker after re-enrollment, protection of later admin edits, and the read-only status query. Evidence is in `outputs/oct31-enrollment-validation.log`; local fixtures are not production identity/status evidence.
