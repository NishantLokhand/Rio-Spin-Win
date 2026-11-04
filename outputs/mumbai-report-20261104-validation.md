# Regional report filtering — 4 November 2026

## Final approved implementation

Applied `20261104000200_preserve_directory_expand_region_filters.sql` to the linked production database. It restores the original licence-verified report view, superseding the earlier view-mapping migration `20261104000100`.

A selected business territory includes its exact saved territory plus directory transactions whose resolved city matches the selected territory name in the same state (case-insensitive, ignores a trailing ` MKT`). Selecting Global outlet directory continues to match its original saved territory exactly. No sales, spins, directory records, stock or outlet selection behavior changed. Territory grouping without a regional filter retains original identities.

## Validation

- `node test/report-directory-territory.mjs`: passed; Mumbai, another region, state isolation, explicit territories, directory totals, date constraints, all-region totals, unchanged view/sales and repeat application.
- `npm run build` in web: passed (136 modules).
- Live rolled-back preview: Mumbai 297 spins; Maharashtra directory 3,918 spins; original territory identities and report row count preserved.
- Production application used a repeatable-read transaction and assertions before commit: Mumbai 297; directory report equals raw directory spins; all territory IDs/names equal original sale snapshots; report row count equals sales row count.
- One new directory spin arrived during validation (3,918 became 3,919). The final assertion compares directory totals against raw records in the same snapshot rather than freezing a live total.

Only these two reporting migrations were executed directly through the Management API; unrelated pending migrations were not run. The final fix is server-side and takes effect when reports refresh. Browser post-deployment verification was unavailable; the live report RPCs were verified directly.
