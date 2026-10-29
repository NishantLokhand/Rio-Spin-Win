# Version 7 rollout — 29 October 2026

Apply `supabase/migrations/20261029000100_static_v7_expiry_allocator.sql` as one complete script in the production Supabase SQL Editor. This file includes its transaction and schema notification. Do not rerun the old 28 October Version 7 patches, or apply the entire outstanding migration directory to a database maintained through SQL Editor.

The migration activates Version 7 for the explicit 41-person list through **4 November 2026, inclusive, India time**. Case, spaces, and punctuation are normalized for matching; each requested name must resolve to exactly one active linked field account. Missing or duplicate matches abort the transaction with the names involved. It also checks the current allocator against the supplied working production Version 6 source before making changes.

| Selected user's stock/rule | ₹10 snack | ₹5 snack | Shades |
| --- | ---: | ---: | ---: |
| Standard, no shades available | 95% | 5% | 0% |
| Shades available | 90% | 6% | 4% |
| Tukaram / Nayan, shades available | 96% | 0% | 4% |
| Tukaram / Nayan, shades depleted | 100% | 0% | 0% |

The two no-₹5 accounts are explicitly identified in the allowlist. Other selected users still require both snack stocks. Shades are always gated by the individual promoter's available stock; nothing replenishes physical inventory automatically.

Version 7 uses cryptographically random draws and shared counters **among selected Version 7 users with the same applicable mix**. Its shade ceiling is `ceil(0.04 × cohort spins)`: this permits an early random shade and at most four by spin 100. Four shades per 100 are not guaranteed. When the ceiling is reached, that draw chooses between the snacks using their relative weights. No scheduled shade positions or catch-up prizes are used.

Version 6 keeps its original function body and allocation counters. Version 7 neither reads nor updates the Version 6 counters. The earlier claim that shared Version 6/7 counters would leave Version 6 unaffected was incorrect; this implementation isolates those counters explicitly. The active base prize-config row stays at Version 6. New spin columns `distribution_version` and `distribution_mode` identify the actual rule used without falsifying its base config ID.

After the SQL succeeds, the admin Prize Structure screen exposes **Version 7 Active**. Turning it off returns subsequent spins to the preserved Version 6 allocator. Expiry also returns users to Version 6 automatically. Old spins, stock movements, and reports are retained. The Version 7 report displays the effective stock-dependent rule and prizes won.

For immediate SQL rollback, run `supabase/rollbacks/20261029000100_disable_v7.sql`. Rerunning the installation migration preserves an already-disabled toggle.

Read-only verification after installation:

```sql
select c.code,s.enabled,s.starts_on,s.expires_on
from public.prize_v7_settings s join public.campaigns c on c.id=s.campaign_id;

select u.full_name,o.mode,o.starts_on,o.expires_on
from public.prize_user_distribution_overrides o
join public.app_users u on u.id=o.user_id
where o.version=7 and o.expires_on=date '2026-11-04'
order by u.full_name;

select distribution_version,distribution_mode,prize_code,count(*)
from public.spins
where distribution_version=7
group by distribution_version,distribution_mode,prize_code;
```

## Validation

Run `node scripts/validate-v7-postgres.mjs` with Docker available. The script creates a new database inside `supabase_db_rio-spin-win-v7-sandbox`, imports the local schema/reference data, installs the supplied V6 baseline, and executes the exact new migration. It never connects to production or modifies the existing sandbox database.

Checks include PostgreSQL compilation/alias checking, migration reruns, 15,000 random draws, the shade cap at every history prefix, stock depletion, no-₹5 restrictions, Version 6's 75/25 regression, isolation of both versions' counters, ten real `play_spin`/handover RPCs and their replays, permission checks, the admin toggle, expiry, rollback, and failed allowlist matching. The full executable tests are in `test/v7-postgres.sql`; the latest execution log is `outputs/v7-postgres-validation.log`.

This is PostgreSQL execution testing with local fixtures, not a claim of live production execution or testing through the phone/browser UI. The local image does not include the production safe-update guard library. Every new UPDATE and conflict UPDATE has an explicit WHERE, and the Version 6 body matches the supplied production snapshot.
