# Connect RIO SPIN & WIN to Supabase (localhost) — step by step

Time needed: about 20 minutes. You need Node.js (already installed) and a web browser.

---

## Step 1 — Create the Supabase project
1. Go to https://supabase.com and sign in. GitHub or Google login is fine.
2. Click **New project**.
   - **Organization:** your organisation, or create one.
   - **Project name:** `rio-spin-win`
   - **Database password:** click *Generate*, then **save it somewhere safe**.
   - **Region:** **South Asia (Mumbai)**
   - **Plan:** Free is fine for testing. Use Pro once the campaign is live.
3. Click **Create new project** and wait 1–2 minutes until the dashboard is ready.

## Step 2 — Create the database (one paste)
1. In the left sidebar, open **SQL Editor** and click **+ New query**.
2. On your computer, open `rio-spin-win/supabase/ALL_IN_ONE.sql` in Notepad or VS Code.
3. Select all (Ctrl+A), copy (Ctrl+C), and paste it into the SQL Editor.
4. Click **Run**, or press Ctrl+Enter. The combined script includes the current schema, prize-allocation rules, mixed-product sales, master-data and inventory features.
   - Expected result: **"Success. No rows returned"**.
   - If Supabase warns about *"destructive operations"*, click **Run this query**. The warning appears because the script contains `revoke` statements.
5. To check it worked, open **Table Editor**. You should see tables such as `states`, `outlets`, `campaigns`, `prizes` and `spins`. The `outlets` table should have 15 rows.

> Run `ALL_IN_ONE.sql` only **once**. If you need to start over, create a new project, or ask for a reset script.
>
> Before importing workbooks on a new project, also run `supabase/migrations/20261001000100_inventory_source_row_import_fix.sql` once. It adds source-row tracking and updates the workbook import function.

### Upgrade an existing project

Do not rerun `ALL_IN_ONE.sql` on a project that already has the app schema. In Supabase **SQL Editor**, run these files in order:

1. `supabase/migrations/20260929000100_cumulative_allocation.sql`
2. `supabase/migrations/20260929000200_cumulative_campaign_defaults.sql`
3. `supabase/migrations/20260930000100_regional_customers_launch_phase.sql`
4. `supabase/migrations/20260930000200_filter_spin_candidate_updates.sql` (only if not already applied)
5. `supabase/migrations/20260930000300_qualify_spin_update_columns.sql` (only if not already applied)
6. `supabase/migrations/20260930000400_multi_product_multi_spin_sales.sql` (only if not already applied)
7. `supabase/migrations/20260930000500_master_inventory_assignments.sql` (only if not already applied)
8. `supabase/migrations/20261001000100_inventory_source_row_import_fix.sql` (run once; needed for inventory workbooks with required source-row tracking)

Run only migrations that are not already applied; never rerun an applied migration. The first two add cumulative percentage allocation, a private ledger, reporting, and campaign-wide scope. Later files add the regional catalogue, spin updates, mixed-basket sales, organizational master/inventory support, and the required inventory workbook source-row field. Existing spin and sale records are retained. The temporary 85%/15% snack allocation remains controlled by the campaign's **Temporary launch phase** setting.

After migrations `20260930000500_master_inventory_assignments.sql` and `20261001000100_inventory_source_row_import_fix.sql` are applied, sign in as Admin and open **Organization & Inventory → Import workbooks**. Select the three supplied workbooks from `source_file` and run the import with the default run key. Then open **Outlet access** and explicitly assign each promoter their authorized outlets; the spreadsheets contain no outlet assignment data. Link any promoter login not matched automatically, then set their optional TSE/MER mapping. The two UP promoters without inventory remain at zero until stock is explicitly issued.

## Step 3 — Security setting: stop public sign-ups
1. Go to **Authentication → Sign In / Providers**. In older dashboards this is **Authentication → Providers → Email**.
2. Turn **"Allow new users to sign up"** **OFF** and save. Only the admin creates users.
3. Leave the Email provider **enabled**. Logins use it behind the scenes.

## Step 4 — Copy your keys
Go to **Project Settings** (the gear icon) **→ API Keys**. Some dashboards call this **Data API**. You need 3 values:

| Value | Where | Used for |
|---|---|---|
| **Project URL** | Project Settings → API / Data API, e.g. `https://abcdxyz.supabase.co` | web app + setup script |
| **anon / publishable key** | API Keys → `anon` `public`, or the *Publishable key* (`sb_publishable_…`) | web app |
| **service_role / secret key** | API Keys → `service_role`, or a *Secret key* (`sb_secret_…`); click *Reveal* | setup script **only** |

⚠️ Never put the service_role / secret key in the web app, in `.env.local`, or anywhere public.

## Step 5 — Connect the web app
1. Open the folder `rio-spin-win/web`.
2. Create a new file named exactly **`.env.local`** in that folder. In Windows Notepad, choose *Save as type: All files*, so it doesn't become `.env.local.txt`.
3. Put this in it, using your own values:
   ```
   VITE_SUPABASE_URL=https://abcdxyz.supabase.co
   VITE_SUPABASE_ANON_KEY=paste-your-anon-or-publishable-key-here
   VITE_USE_PROXY=false
   VITE_LOGIN_DOMAIN=login.riospinwin.app
   ```
   Don't use quotes or spaces around `=`.

## Step 6 — Create the admin and test users
Open a terminal (PowerShell or Command Prompt) and run:
```
cd path\to\rio-spin-win
npm install
node scripts/create-users.mjs
```
The script:
- reads the Project URL from `web/.env.local`, so press Enter to accept it;
- asks for the **service_role / secret key**, so paste it;
- asks what to create: choose **2** (admin + demo users). Press Enter to accept the default admin login `admin` / `admin123`, or type your own.

You should see:
```
✓ admin      login: admin        PIN: admin123
✓ supervisor login: sup.lucknow  PIN: 222222
✓ promoter   login: 9876500001   PIN: 111111
✓ promoter   login: 9876500002   PIN: 111111
✓ Issued one prize kit (152/34/10/3/1) to each new promoter
```

### Create the isolated production test promoter

For a single test login `9556600000` with one private outlet named `Demo outlet`, run `npm run test-promoter` from the repository root. Enter the **production** Supabase URL, service-role key, and requested password when prompted. The key and password are hidden and are not saved to the repository. The script reuses an active TSE only to satisfy the outlet hierarchy, leaves the promoter's supervisor unset, assigns only the demo outlet, and creates no prize stock. Admins retain access through the existing policies; other promoters and supervisors do not receive access. No extra SQL Editor change is needed after migration `20260930000500_master_inventory_assignments.sql`.

### Create staff mobile logins from the consolidated roster

After importing the area workbooks into **Organization & Inventory**, run `npm run create-staff-logins` from the repository root. The script reads `source_file/MH-UP inventory DETAILS.xlsx`, matches each PROMOTER/TSE/MER to an existing organizational master row, and creates a mobile-number login with the app role **promoter**. Initial passwords start at `111111` and increment for each matched person in workbook order. TSE and MER keep their organizational designation; they are not given separate app roles. The script skips missing/ambiguous master matches and conflicting existing accounts, and writes the private credentials report to `staff-login-credentials.local.csv` (ignored by Git). It does not create master records, assign outlets, or issue stock. Admins must assign authorized promoter outlets and inventory separately before sales can be recorded. No SQL Editor change is required.

## Step 7 — Start the app on localhost
```
cd web
npm install
npm run dev
```
Open **http://localhost:5173**.

The yellow **DEMO MODE** strip should **not** appear. If it does, `.env.local` wasn't found or still has placeholder values. Fix it, then stop the server with Ctrl+C and run `npm run dev` again.

## Step 8 — Test the full flow
1. **Promoter:** log in as `9876500001` / `111111`.
   - Select Uttar Pradesh → Lucknow Central → Rahul Sharma → Modern Wines.
   - Tap START NEW SALE, pick a SKU, then a quantity.
   - Tap SPIN NOW, then PRIZE HANDED OVER.
2. **Admin:** log out, then log in as `admin` / `admin123`.
   - Dashboard, Reports and Transactions should show the sale.
   - Prize Pool should show one total campaign spin and its actual prize distribution; 200 is the reference mix, not a cap.
3. **Supervisor:** log in as `sup.lucknow` / `222222`. You should see only Ravi and Sneha.

To test on your phone on the same Wi-Fi: run `npm run dev -- --host` and open the "Network" address it prints, e.g. `http://192.168.1.5:5173`.

---

## Optional — enable "Users" page actions (create promoters, reset PIN, disable) from the admin screen
The admin **Users** page calls a Supabase Edge Function named `admin-users`. For basic testing you can skip this, because Step 6 already created the users.

To enable it, the easiest way is the dashboard:
1. **Edge Functions → Deploy a new function → Via Editor.**
2. Name it exactly **`admin-users`**.
3. Replace the sample code with the contents of `supabase/functions/admin-users/index.ts` and click **Deploy**.

You don't need to add secrets: `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are provided automatically.

Alternatively, use the command line:
```
npx supabase login
npx supabase functions deploy admin-users --project-ref abcdxyz
```

## Optional — prize image uploads
1. **Storage → New bucket.** Name it `prize-images` and tick **Public bucket**.
2. In the SQL Editor, run `supabase/migrations/20260928000600_storage.sql`. Skip the first `insert` line if the bucket already exists.
   - If you get "must be owner of table objects", add the policies from **Storage → Policies** instead:
     - allow `SELECT` for everyone;
     - allow `INSERT`/`UPDATE`/`DELETE` for authenticated users with `public.is_admin()`.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Yellow DEMO MODE strip still shows | `.env.local` is missing, misnamed (`.env.local.txt`) or has placeholders. Restart `npm run dev` after fixing. |
| "Wrong mobile/username or PIN" | The user wasn't created (re-run Step 6), or it's a typo. PINs are case-sensitive. |
| "No app profile for this login" | The auth user exists but the `app_users` row doesn't. Delete the user in Authentication → Users and re-run Step 6. |
| "No network connection" / login hangs | Your internet provider may be blocking `supabase.co`. Set `VITE_USE_PROXY=true` in `.env.local` and restart `npm run dev`. The app then goes through `localhost:5173/sb`. |
| "Prize stock needed" when starting a sale | The promoter has no stock. As admin, go to Promoters & Stock → Stock → *Fill one standard pool kit* → Save. |
| "No active campaign covers this outlet" | The outlet's state isn't in the campaign. Go to Campaigns → Edit → States covered. |
| Script says "Cannot read the database" | `ALL_IN_ONE.sql` wasn't run, or you used the wrong URL or key. |
| SQL error "type user_role already exists" | The script was already run once on this project. Use a fresh project. |
