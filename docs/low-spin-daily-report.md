# Less than 10 spins users

The Reports page has a separate daily report for current active field accounts
with 0–9 recorded spins, across all campaigns. It excludes test/demo accounts,
deleted accounts, reporting exclusions and Sneha Yadav. The date uses India
business time. State/City/Area come from the linked user profile; visited outlets
retain their recorded identity. Sales quantities are counted once per bill.
Market uses the existing reviewed master mapping, including Ritik's Moradabad
correction. Future master mapping corrections should also update this report.

## Cloud email

- Sender: **ai.automation@gooddropwine.com** via Gmail API.
- To: **sanjay.waghela@gooddropwine.com**.
- CC: **shiv.kumar@gooddropwine.com**, **chandra.mohan@gooddropwine.com**.
- First scheduled run: **10:00 AM Asia/Kolkata** each day, for yesterday.
- Burgundy HTML dashboard (`#722F37`) with a real `.xlsx` attachment containing
  dashboard, market summary and the complete 0–9 spin user list.
- Recipient addresses are fixed on the server. Incoming requests cannot change them.

Install `20261124000100_less_than_ten_spins_report.sql`, then
`20261124000200_low_spin_email_delivery.sql`. Deploy `send-low-spin-report`.
This endpoint authenticates its own requests: admin JWT verified through Auth,
existing service-role key, or a private matching cron token. Deploy this function
with gateway `verify_jwt=false` so the cron token can reach its own verification;
unauthenticated and field-user requests are rejected before reading or sending.
No browser client receives a service key, mail credential or email payload.

### One-time Gmail authorization

Use an organization's Google Cloud project with Gmail API enabled. Configure
an OAuth client for the automation and request only
`https://www.googleapis.com/auth/gmail.send` with offline access. The account
owner must authorize **ai.automation@gooddropwine.com**, not a different mailbox.
For a Workspace organization, use an internal OAuth app if the administrator
allows it. External OAuth apps left in Testing can have expiring refresh tokens;
complete the organization's production setup before relying on daily delivery.
Do not use a Gmail password or store credentials in source code.

Store these as encrypted **Supabase Edge Function secrets**:

- `GMAIL_CLIENT_ID`
- `GMAIL_CLIENT_SECRET`
- `GMAIL_REFRESH_TOKEN`
- `LOW_SPIN_CRON_TOKEN` (a private random token, at least 32 characters)

Store the same cron token in Supabase Vault as `low_spin_report_token`, and the
function URL as `low_spin_report_url`:
`https://vkfhwianezrqmoxrspac.supabase.co/functions/v1/send-low-spin-report`.
No credential value belongs in SQL files, a chat message, Git or the frontend.

### Test, then enable

Invoke the function using an authorized admin/service token with JSON:

```json
{"mode":"preview","report_date":"2026-11-23"}
```

Preview returns recipient, filename and counts without sending anything. Then:

```json
{"mode":"test","report_date":"2026-11-23"}
```

Verify Gmail accepted the message, its recipients, burgundy body and workbook.
Check inbox delivery separately: API acceptance does not establish inbox delivery.
Only then run `supabase/reports/enable_daily_low_spin_email.sql`; that script
refuses activation without a successful test record and the required Vault entries.
The UTC schedule is 04:30, with guarded retries at 04:40 and 04:50.

The private delivery table has a unique report-date/delivery-kind key and an
atomic lease. The exact prepared payload is retained for retries. Gmail does not
offer a send idempotency key: an ambiguous timeout after dispatch is marked
`uncertain` and **never automatically resent**. Check the sender's Sent folder
before any manual intervention. Pre-send failures may retry up to three times.

Read-only operational check (SQL Editor, administrator only):

```sql
select report_date,kind,status,attempts,provider_id,last_error,created_at,sent_at
from public.low_spin_email_deliveries order by report_date desc,kind;
```

The schedule will not activate until mail credentials and authorization are
configured. The app report works independently of email configuration.

## Rollback

Run `supabase/rollbacks/20261124000100_disable_low_spin_email.sql` to stop future
scheduled emails. It retains report access and delivery history. Revert the
report UI commit if the button must be removed. No prize allocation, V6/V7/V8,
inventory, promoter workflow or existing reporting function is modified.

## Validation

Before release, the report was checked against a disposable local PostgreSQL
fixture for 0/1/9/10-spin boundaries, Maharashtra/Uttar Pradesh grouping, date
boundaries, user exclusions, role scopes, unchanged existing function bodies,
delivery leases and rollback behavior. Separate local checks covered the report
modal, state/type filters, CSV/XLSX export, HTML escaping, workbook contents,
fixed recipients, authorization failures and duplicate/ambiguous-send handling.
The production SQL report totals were also compared with the saved live snapshot
for 23 November 2026. These checks did not send synthetic email or mutate live
spin, prize or inventory data.

The local validation harnesses use machine-specific fixtures and are not part of
the production change set. Release builds use a clean HEAD copy with only the
scoped report changes.
