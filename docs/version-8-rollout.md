# Version 8 — daily third-spin speakers

Version 8 is an additional scheduled-prize rule for the following 12 accounts. Pradeep Bharadwaj is excluded. The quantities below are reference information supplied by the administrator; **the migration never issues stock**.

| Exact account name | Reported speakers |
| --- | ---: |
| AJAY PANDURANG DOLEKAR | 6 |
| KARAN KALE | 6 |
| SUNIL KUMAR YADAV | 10 |
| VIVEK DHARMADHIKARI | 6 |
| ROHAN RATHOD | 7 |
| VIKAS SHRIKRUSHANA TAYADE | 7 |
| HARISHACHANDRA PATEL | 10 |
| NIKHIL KAROTE | 7 |
| CHETAN MADHUKAR PAUNIKAR | 7 |
| PAVAN PANBIHADE | 6 |
| SARANG R BORKAR | 7 |
| SAURABH PATIL | 7 |
| **Total** | **86** |

For each selected user, the third recorded RSW-2026 campaign spin of the India-time day awards one in-stock speaker instead of the normal prize. The daily count includes all their bills/outlets and retained spin records, including pending or subsequently undelivered results. Replays do not add spins. Cancelled bills with no spin do not count.

If speaker stock is unavailable on spin three, that spin uses the user's ordinary Version 7/Version 6 rule. Restocking afterwards does not produce a catch-up speaker that day. Enabling Version 8 after three spins also produces no catch-up. A user who completes fewer than three spins gets no scheduled speaker.

The scheduled speaker reserves and deducts inventory through the existing play-spin and handover workflow. It has its catalogue/configured unit cost and is recorded as `distribution_version=8`, `distribution_mode=speaker_third_daily`. It does not increment V6/V7 allocation counters. All ordinary spins continue through the exact preserved current V7/V6 dispatcher. Adding speakers to any other user's inventory does not make them V8-eligible.

The database serializes selected users' daily draws across different bills/devices and enforces one award record per user/date. A stock release or rollback toggle does not erase that record. Transaction failure rolls back its reservation, claim, and spin together.

The stock-readiness wrapper permits an available scheduled speaker on spin three even if snacks have just run out. For all other cases it calls the original stock-readiness function unchanged.

## Install and activate

1. Deploy the frontend and apply the complete file `supabase/migrations/20261029000300_scheduled_v8_speakers.sql` in Supabase SQL Editor. The migration checks the current entry-function fingerprints and requires exactly one active field account for each name. A mismatch aborts the entire migration. It contains its own schema reload notification.
2. Installation leaves Version 8 **disabled**. Inventory, existing V6/V7 settings, and their allocator functions remain unchanged. Rerunning preserves the toggle's current state and all award records.
3. Open **Prize Structure → Version 8** and confirm the 12 users and their existing stock in **Reports → Version 8 speakers**.
4. Turn **Version 8 Active** on. Users who have already passed their third spin wait until their next activity day.

Version 8 has no automatic end date by default. Version 7 still expires on 4 November 2026; thereafter ordinary prizes use V6 while the independent V8 third-spin speaker rule continues. Disable V8 whenever it is no longer required.

The V8 report supports selecting a day and CSV/Excel downloads. Speaker balances are current available stock; activity and handover status relate to the selected day.

## Rollback

- Normal: switch **Version 8 Active** off, or run `supabase/rollbacks/20261029000300_disable_v8.sql`. Subsequent draws use the current V7/V6 route. Re-enable without resetting the daily allowance.
- Emergency route restoration: run `supabase/rollbacks/20261029000301_restore_pre_v8_routes.sql`. This disables V8 and restores literal copies of the exact pre-V8 allocator entry and stock-readiness functions. It does not remove spin, inventory, or award history.

Do not rerun historical V7 installation/repair migrations to roll V8 back; use the above scripts.

## Validation

`node scripts/validate-v8-postgres.mjs` creates a new database inside the local Docker Supabase container, copying the prior validated local V7 fixture database. It never contacts production. `test/v8-postgres.sql` drives actual `play_spin` and `confirm_handover` calls in PostgreSQL, plus real simultaneous database sessions.

Checks cover all 12 accounts, disabled and unselected users, third-spin selection across bills/outlets, missing stock and later replenishment, 100+ spins per day, same-sale retries, concurrent different-sale draws, stock deduction/release, transaction rollback, India-time midnight, V7 expiry, private permissions, normal rollback, emergency recovery fingerprints, idempotent migration reruns, and rejection of missing users. Source hashes verify existing V6/V7 allocators, play-spin, and handover bodies are preserved. Output is saved in `outputs/v8-postgres-validation.log`.

The local PostgreSQL image lacks the production safe-update library. All new UPDATE/conflict UPDATE statements have explicit WHERE conditions. The migration is still subject to the production fingerprint/user preflight checks; local execution is not a claim of production execution.
