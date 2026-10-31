# Four users in one transaction — 31 October 2026

Use **only** `supabase/migrations/20261031000300_enroll_four_users_v7_v8_atomic.sql` for this request. It replaces the need to run the earlier individual Tushar, Ashish/Sujal and Harshraj files. Run the entire file in one production Supabase SQL Editor execution, not selected fragments or the whole migrations directory. No webapp deployment is required.

| Account | Requested change | Already-entered stock |
| --- | --- | --- |
| TUSHAR SURESH AMRUTKAR | Standard V7: 95% INR10 / 5% INR5 without shades; existing 90/6/4 if shades are later stocked | 25 INR5, 82 INR10, 3 speakers |
| ASHISH RAMU KALWAL | Select for existing V8 third-daily-spin speaker rule | 10 speakers |
| SUJAL KALIDAS WANKHEDE | Select for existing V8 third-daily-spin speaker rule | 10 speakers |
| HARSHRAJ SHELAR | Preserve an already-enabled V8 row exactly; enroll if missing or disabled | 20 speakers |

Tushar's existing V8 membership is retained. His three speakers alone do not create a new V8 membership. The V8 recipients retain their ordinary V7/V6 assignment. Existing enabled V8 rows retain their original reference quantity and creation timestamp. Current inventory is never issued, replenished or reset. Positive available stock differing from the stated quantities produces a notice, because live consumption/reservations can change the balances.

The file does not create, replace or rewrite any prize function. The prior SQL alias and unsafe-update issues are avoided by using membership writes only, with explicit WHERE clauses on every UPDATE/conflict UPDATE/DELETE. Existing allocators, award history, daily claims, inventory movements, users and global settings remain untouched. Production's safe-update extension is not available in the local test image, so the local tests do not reproduce that extension itself.

The script checks for existing V7/V8 routes and active settings, inventory tracking, launch phase off, the active config/catalogue, unique normalized identities, active linked field profiles, available required stock and ordinary-spin stock readiness. It does not reinstall anything or activate/extend global settings to pass those checks. Any failure rolls back **all four** users' changes, including the new private snapshot. Lock waits are bounded to five seconds and each statement to 45 seconds. It briefly locks only the affected user/membership/inventory rows and reads campaign/settings under shared row locks; it does not take an application-wide maintenance lock.

The combined file can be used if earlier individual enrollment files were already applied. It snapshots the actual current memberships independently. In particular, it corrects Tushar's earlier no-INR5 category to standard V7, preserves an already-effective standard V7 row exactly, and preserves already-enabled V8 rows. Repeating the combined file after success does not overwrite later administrator membership edits.

After successful execution, review the four result rows. Tushar must show `effective_v7_category = snacks`. Ashish, Sujal and Harshraj must show `selected_for_v8 = true` and `v8_effective = true`. For Harshraj, `v8_changed = false` on the first combined run means his enabled membership was already present and was left unchanged. Available balances and today's spin counts are shown. Enrollment after daily spin three does not provide a catch-up speaker; existing daily claims are retained.

Optional rollback: run the complete `supabase/rollbacks/20261031000300_restore_four_users_v7_v8_atomic.sql` only if reverting this combined enrollment is necessary. It restores only memberships the combined file changed, retaining all current stock/activity and preexisting enabled memberships. A later edit to a membership it would restore aborts the entire rollback rather than overwriting the edit. Earlier individual scripts have separate snapshots; do not interleave their rollback files with this combined workflow.

Validation: `node scripts/validate-four-users-atomic.mjs`. The exact enrollment and rollback are exercised in a new isolated local database cloned from the validated V7/V8 fixture. Tests include 110 real spin/handover calls across all four users, third-spin-only speaker awards and replay, standard Tushar V7 with existing V8 retained, exact stock deductions, preservation of an already-enabled Harshraj row, disabled-row activation, missing-Harshraj enrollment, reruns, concurrent enrollment, atomic failures at the last account, missing/duplicate/inactive/wrong-role/unlinked identities, reserved stock, disabled V8, expired V7, rollback after live-style activity, later-edit protection and unchanged existing function bodies. Source hashes and output are recorded in `outputs/four-users-atomic-validation.log`.

Production execution and live membership verification have not been performed from this chat. Supabase CLI has no authenticated production session. The returned production result rows are the confirmation of actual enrollment, not local fixture output or the Git push.
