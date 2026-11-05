-- Restore the previous Transactions frontend before removing this reporting RPC.
-- No transactions, stock, prize settings, policies or other reports are modified.
begin;
set local lock_timeout = '5s';
drop function if exists public.transaction_report_page(jsonb,uuid,timestamptz,integer);
commit;
notify pgrst, 'reload schema';
