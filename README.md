# RIO SPIN & WIN — Field Activation App (v1)

Good Drop Wine Cellars · consumer spot-selling activations · campaign **RIO SPIN & WIN 2026**

Customer buys Rio → promoter records the sale (3 taps) → customer spins the wheel → server decides the prize from a controlled pool → promoter hands it over → stock and reports update.

```
rio-spin-win/
├─ supabase/
│  ├─ migrations/        6 SQL files — run in order (schema, core, spin engine, admin API, security, storage)
│  ├─ seed.sql           demo hierarchy, 4 SKUs, 5 prizes, campaign + 200-spin prize structure
│  └─ functions/admin-users/   Edge Function: create users, reset PIN, enable/disable
├─ web/                  React (Vite) mobile-first web app — promoter + supervisor + admin
├─ scripts/create-users.mjs    bootstrap first admin / demo users
└─ test/                 local test harness (Postgres + PostgREST), SQL engine tests, browser E2E
```

---

## 0. Try it now — demo mode (no Supabase needed)

```bash
cd web
npm install
npm run dev          # open http://localhost:5173
```

If `web/.env.local` does not exist, the app starts in **DEMO MODE**. Demo mode includes:

- sample outlets, SKUs and prizes;
- 6 days of sample sales;
- one-tap demo logins on the login screen.

A few things to know about demo mode:

- **Data is stored only in that browser.** To see a promoter's sales as admin, log out and log in as admin in the **same browser**.
- **"Reset demo data"** on the login screen starts fresh.
- **Prizes are drawn in the browser**, so demo mode is for walkthroughs and testing only. Real activations must use Supabase: create `.env.local` as below and restart.
- **Testing on your phone:** run `npm run dev -- --host` and open the "Network" address it prints, on the same Wi-Fi.
- **Forcing demo mode** even when `.env.local` exists: set `VITE_DEMO_MODE=true`.

---

## 1. Go-live setup (about 30 minutes)



###

### 1.3 First-day admin checklist
1. **Outlets & Masters → Upload Outlet Master.** Download the template, fill it in, and upload it. New States, Territories and TSEs are created automatically.
2. **Products / SKUs** and **Prizes.** Upload a prize image, set the low-stock threshold, and choose the wheel segments each prize lands on.
3. **Campaigns.** Set dates, budgets, states covered, SKUs and the spin rule.
4. **Prize Structure.** Check the 200-spin pool (152 / 34 / 10 / 3 / 1 = ₹2,000 = ₹10.00 per spin). Add a state-specific structure if needed.
5. **Users.** Create supervisors and promoters. Promoters log in with their mobile number and a 6-digit PIN.
6. **Promoters & Stock → Stock → "Fill one standard pool kit".** Issue each promoter's prize kit.

---

## 2. How the prize draw works

The phone **never** chooses a prize. It makes three idempotent server calls:

| Step | Call | What the server does |
|---|---|---|
| Promoter taps quantity | `record_sale(sale_id, outlet, sku, qty)` | Validates the promoter, outlet, SKU, budget and stock. Saves the sale with a snapshot of the whole hierarchy. |
| Customer taps SPIN NOW | `play_spin(sale_id)` | Takes the next slot from the promoter's hidden shuffled pool that the promoter has physical stock for. Reserves 1 unit and writes the spin. |
| Promoter taps PRIZE HANDED OVER | `confirm_handover(spin_id)` | Deducts the stock through the ledger and completes the transaction. |

`sale_id` is generated on the phone. Retries, refreshes and weak-signal resends therefore always return **the same result**, and a result can never be drawn twice.

### 2.1 Current rule (configurable per campaign, no code changes)

//kept hidden onPurpose

- **Shuffling:** pools are shuffled with Postgres `gen_random_uuid()`, which uses a cryptographic random generator.
- **Hidden sequence:** the pool-slot table has **no read access for anyone**, including admins. Admins see only the remaining quantities of each prize.

---

## 3. Fraud controls built in

- **One customer at a time.** A new sale is refused while a won prize is still pending hand-over. After a refresh, the app resumes that same prize.
- **No re-spins.** One spin per sale by default, controlled by `spins_per_sale`. Replaying a spin returns the original result.
- **No cancelling after the spin.** A sale can be cancelled only *before* the spin, and every cancellation is logged and counted.
- **Promoters have read-only access to everything.** They cannot edit history, stock, prizes, outlets or probabilities. All writes go through validated server functions, and database triggers block edits to spin results and sale snapshots.
- **Tamper-evident audit log.** Every audit record is SHA-256 chained to the previous one and cannot be updated or deleted. Admins can re-verify the whole chain with **Audit Log → Verify hash chain**.
- **Automatic flags** (thresholds editable per campaign):
  - rapid spins
  - high daily spin count
  - high-value win concentration
  - outside working hours
  - incomplete hand-overs
  - excessive cancellations
  - repeated "Outlet Not Listed" requests
  - stock marked missing or damaged
  - slow redemption
- **History stays as recorded.** Transactions keep the State, Territory, TSE, outlet, promoter, SKU and prize names and costs from the moment of the sale, even if master data changes later.
- **Offline behaviour.** Outlet lists, the hierarchy, products, profile, recent outlets and the dashboard work offline from the phone's cache. **Recording a sale and spinning need signal.** This is deliberate: an offline draw can be manipulated.

---

## 4. Roles

| | Promoter | Supervisor | Admin |
|---|---|---|---|
| Record sales / run spins | ✓ | | |
| See own performance & stock | ✓ | | |
| See their promoters, reports, drill-down | | ✓ (own promoters) | ✓ (all) |
| Issue / return / damaged / missing stock | | ✓ | ✓ (+ adjustments) |
| Resolve stuck hand-overs, flag & review activity | | ✓ | ✓ |
| Approve outlet requests | | if authorised | ✓ |
| Masters, campaigns, prize structures, pools, users, audit, exports | | | ✓ |
| Override the ₹10 cost target | | | only if authorised |

---

## 5. Integrations (FieldAssist SFA, ERP, CRM, WhatsApp…)

- **REST API.** Supabase exposes every table and view as REST automatically, for example `GET /rest/v1/v_transactions?date=gte.2026-10-01` using a service or integration user key.
- **Mapping keys.** `external_ref` columns on states, territories, TSEs, outlets and products hold SFA and ERP codes.
- **Future features already in the schema** (switch on per campaign):
  - `sale_validations`: invoice, receipt, QR, barcode, photo or retailer confirmation
  - `consumers` and `capture_consumer`: optional consumer data capture
  - `validation_rules`

---

## 6. Local testing (what was verified)

`test/` contains a Supabase-compatible local stack: Postgres 16 with an auth stub, PostgREST, and a mini auth gateway.

- **`engine_test.sql`**
  - 230 spins for promoter 1: pool 1 = exactly 152/34/10/3/1, and pool 2 was created automatically.
  - Refreshing or replaying a spin returns the identical prize.
  - Promoter 2 had no speaker stock: 199 spins with no speaker awarded, then blocked; after the supervisor replenished, the deferred speaker was awarded and pool 1 was still exact.
  - Promoters cannot read pool slots, write spins, call internal functions or adjust stock.
  - A second spin, cancelling after a spin, and a new sale while a prize is pending are all refused.
  - A prize structure above ₹10 is blocked unless overridden; a pool-size mismatch is caught.
  - A Mumbai supervisor cannot see Lucknow data.
  - The audit chain verifies intact, and direct edits to the audit log fail.
- **`modes_test.sql`:** the substitute, weighted-random and regenerate-now modes.
- **`e2e.mjs`:** the full promoter journey on an Android-size screen (login → State/Territory/TSE/Outlet → change outlet with recent + search → 3 sales with spin and hand-over → refresh resumes the same prize → Outlet Not Listed), every admin page, and the supervisor view on mobile.

Two parts could not be run locally because they depend on Supabase-hosted services, and need a quick check after deployment:

- the `admin-users` Edge Function (the local stand-in mirrors it);
- prize-image upload to Supabase Storage.

To run the tests:

```bash
test/reset_db.sh && psql -h /var/tmp/riopg -p 54322 -U postgres -d rio -f test/engine_test.sql
```
