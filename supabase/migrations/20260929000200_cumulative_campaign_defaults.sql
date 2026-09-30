-- Make the existing active RIO campaign use one campaign-wide cumulative
-- ledger. Historic spins remain unchanged; the allocator seeds its ledger from
-- their persisted prize results the first time the campaign is spun again.
update public.campaigns
   set pool_scope = 'campaign'
 where status = 'active';

