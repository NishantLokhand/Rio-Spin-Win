# Transactions report: bills, spins and SKU sales

This change is confined to the Transactions screen and its downloads. Existing `v_transactions`, the Data Export screen's shared legacy column/filter exports, all other reporting functions, and every sale/spin/inventory/prize workflow remain unchanged.

## Datasets

- **Bills / Sales:** one row per Bill ID. The full basket quantity is counted once. Cancelled bills stay visible with their original entered quantity but contribute zero to `Recorded Units (Excl. Cancelled)`. Open/partial bills retain their entered units and expose recorded/unused spins and prize handover counts.
- **Spin / Prize Details:** one row per actual recorded spin. There is no repeated bill quantity or basket to sum as sales. Bill IDs link prizes to their bill. Base configuration and applied distribution version/mode are separate fields. Missing historical rule values are `Not recorded`; no rule is inferred from the prize. Spin and handover dates/times are separately shown in IST. A prize with no handover timestamp remains blank in those fields.
- **SKU Sales:** one row per bill/product line. The SKU units occur once, with no duplicated prize costs. Old bills without `sale_items` use the original bill SKU/quantity and are labelled `Legacy bill`. Quantity inconsistencies are visible through the bill data-check column rather than silently hidden.

The date filter selects **bill business dates**, preserving the previous Transactions filter semantics. Actual spin/handover timestamps can fall on later dates and are labelled explicitly. A SKU filter selects bills containing that product for the Bills and Spins views, while SKU Sales contains only the matching product lines. The screen separately shows selected-SKU units and whole-basket units.

Recorded prize value includes all spin-result values, including prizes subsequently marked not redeemed. Handed-over prize cost includes only `handed_over` results. It is a record of app-confirmed handovers, not independent physical-delivery evidence. Unspun bills never generate a fake prize row.

Excel contains `Bills`, `Spins`, and `SKU Sales`; CSV has one button for each dataset. Excel dates/times are native numeric cells with date/time formats, automatic filters and frozen first rows. The screen shows at most 300 rows of the selected view, while KPIs and downloads use the complete filtered dataset. Detailed metadata columns are included in downloads.

## Installation

1. Apply **only** `supabase/migrations/20261105000100_transaction_report_datasets.sql` in the owner's Supabase SQL Editor. It adds the new SELECT-only, STABLE, SECURITY INVOKER function `transaction_report_page(jsonb,uuid,timestamptz,integer)` and grants its execution to authenticated users. It does not modify any existing table data, table structure, view, policy, allocator, trigger, permission on an existing object or other function. The file contains its own schema reload notification.
2. Deploy the frontend containing the Transactions changes after the SQL function is installed. Before installation, the updated screen displays an installation message instead of falling back to a misleading legacy dataset.
3. Open Transactions and use Refresh report. Confirm bill, SKU and spin totals for the desired filters and try each CSV/Excel download.

Do not replay unrelated pending migrations to install this report. This change has not been applied to production from this chat.

## Read consistency and scope

The server retains the existing reporting-exclusion policy and invokes it as the signed-in staff member. Caller row-level security on sales/spins/items remains active. Anonymous execution is denied; a promoter cannot use this staff report. Historical snapshots are displayed as recorded; no outlet identity is repaired, merged or reassigned.

Pages use immutable Bill IDs and a fixed server-generated cutoff. Bills and new spins created after that cutoff are excluded until Refresh report. Each bill's SKU/spin details are returned together in one statement snapshot, so all three frontend datasets derive from the same bill payload. Handover statuses, bill statuses and SKU edits reflect when each page was read; a multi-page export is **not** a single historical MVCC snapshot across the entire load. The interface states this explicitly. Concurrent new spins can produce a stored-versus-loaded count warning; refreshing includes the later activity.

The frontend discards stale loads after filter changes. Duplicate/missing bill or spin identities, non-advancing pagination and incomplete responses fail explicitly rather than producing silently understated/doubled totals.

## Validation

- `node --test test/transaction-report.test.mjs` checks dataset grain, mixed-SKU filtering, partial/cancelled/unspun bills, unknown historical rules, cross-date fields, invalid IDs/quantities, pagination/abort behavior, and native Excel date/time cells, three sheets, autofilters and frozen panes.
- `node scripts/validate-transaction-report.mjs` uses a newly created local PostgreSQL database copied from the validated V6/V7/V8 sandbox. It reconstructs the supplied 220-row export in local fixtures and verifies **40 bills, 220 units, 220 spins, four speakers and INR2,115**. It also tests 264-bill pagination, filters, legacy fallback, staff/supervisor/anonymous/promoter access and report execution inside read-only transactions. All existing public table contents, function bodies/ACLs, view definitions and RLS policies are fingerprinted before/after migration, reads, reruns and rollback. See `outputs/transaction-report-validation.log`.
- The localhost headless browser check renders the actual Transactions component against that local SQL reporting RPC, exercises filtering/empty results and real CSV/Excel downloads, reopens the downloaded Excel to reconcile totals, and checks light/dark/narrow layouts and sticky headers. See `outputs/transaction-report-ui-validation.log`. The temporary browser bridge is test-only and is not included in the application build.
- `npm run build` from `web` validates the production frontend bundle.

## Rollback

Restore the previous frontend build to return to the previous Transactions screen. Keeping the unused new read-only function temporarily is harmless. To remove this report's database addition as well, run `supabase/rollbacks/20261105000100_remove_transaction_report_datasets.sql` **after** restoring the previous frontend. It only drops the new reporting RPC, is safe to repeat, and preserves all existing activity and settings. Never disable V7/V8 or change prize configuration to roll back this reporting-only change.
