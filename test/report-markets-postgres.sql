-- Execute only through validate-report-markets-postgres.mjs in its NEW local DB.
do $$
declare result jsonb; actor uuid; target uuid; expected integer; before_count integer; v_role text; v_value jsonb; payload jsonb; org_id uuid;
begin
  -- Neither migration may rewrite existing accounts, geography or work history.
  if exists((select * from public.app_users except select * from public.market_before_accounts) union all (select * from public.market_before_accounts except select * from public.app_users)) then raise exception 'Accounts changed'; end if;
  if exists((select * from public.org_people except select * from public.market_before_profiles) union all (select * from public.market_before_profiles except select * from public.org_people)) then raise exception 'Org geography changed'; end if;
  if exists((select * from public.sales except select * from public.market_before_sales) union all (select * from public.market_before_sales except select * from public.sales)) then raise exception 'Sales changed'; end if;
  if exists((select * from public.spins except select * from public.market_before_spins) union all (select * from public.market_before_spins except select * from public.spins)) then raise exception 'Spins changed'; end if;
  select id into actor from public.market_test_actors where kind='admin';
  perform set_config('request.jwt.claim.sub',actor::text,true);
  result:=public.get_report_user_markets();
  if exists(select 1 from public.market_test_master m where not exists(select 1 from jsonb_array_elements(result) r where r->>'user_id'=m.id::text and r->>'market'=m.market)) then raise exception 'Login mapping mismatch'; end if;
  if exists(select 1 from jsonb_array_elements(result) r where (select count(*) from jsonb_object_keys(r))<>2) then raise exception 'Lookup leaked matching identifiers'; end if;
  raise notice 'PASS: all 202 logins mapped, disabled history retained, only user_id and Market returned';
  -- Same name must not influence the result. All 202 alternative code matches.
  update public.app_users u set login_id='local-code-'||m.n,full_name='Identical name' from public.market_test_master m where u.id=m.id;
  update public.promoters p set promoter_code=m.code from public.market_test_master m where p.user_id=m.id;
  result:=public.get_report_user_markets();
  if exists(select 1 from public.market_test_master m where not exists(select 1 from jsonb_array_elements(result) r where r->>'user_id'=m.id::text and r->>'market'=m.market)) then raise exception 'Promoter-ID mapping mismatch'; end if;
  raise notice 'PASS: all 202 Promoter IDs map independently of names';
  update public.app_users u set login_id=m.login from public.market_test_master m where u.id=m.id;
  update public.promoters set promoter_code='CODE-CONFLICT-FREE' where user_id=(select id from public.market_test_master where n=2);
  update public.promoters set promoter_code=(select code from public.market_test_master where n=2) where user_id=(select id from public.market_test_master where n=1);
  result:=public.get_report_user_markets();
  if not exists(select 1 from jsonb_array_elements(result) r join public.market_test_master m on r->>'user_id'=m.id::text where m.n=1 and r->>'market'=m.market) then raise exception 'Login did not take precedence'; end if;
  select id into target from public.market_test_actors where kind='field';
  insert into public.org_people(designation,employee_name,source_key,source_system,auth_user_id,state_raw,market_raw,market_override) values('MER','Synthetic fallback','LOCAL-FALLBACK','admin',target,'Maharashtra','Raw market','Manual market');
  result:=public.get_report_user_markets();
  if not exists(select 1 from jsonb_array_elements(result) r where r->>'user_id'=target::text and r->>'market'='Manual market') then raise exception 'Profile fallback failed'; end if;
  update public.org_people set market_override=null where auth_user_id=target;
  result:=public.get_report_user_markets();
  if not exists(select 1 from jsonb_array_elements(result) r where r->>'user_id'=target::text and r->>'market'='Raw market') then raise exception 'Raw fallback failed'; end if;
  raise notice 'PASS: login precedence and new-user profile fallback';
  perform set_config('request.jwt.claim.sub',(select id::text from public.market_test_actors where kind='supervisor'),true);
  result:=public.get_report_user_markets();
  if jsonb_array_length(result)<>101 then raise exception 'Supervisor scope wrong'; end if;
  if exists(select 1 from jsonb_array_elements(result) r where not exists(select 1 from public.market_test_master m where m.n<=101 and r->>'user_id'=m.id::text)) then raise exception 'Supervisor sees other team'; end if;
  perform set_config('request.jwt.claim.sub',target::text,true);
  begin perform public.get_report_user_markets(); raise exception 'Field caller accepted'; exception when others then if sqlerrm<>'STAFF_ONLY' then raise; end if; end;
  perform set_config('request.jwt.claim.sub','',true);
  begin perform public.get_report_user_markets(); raise exception 'Anonymous caller accepted'; exception when others then if sqlerrm<>'NOT_AUTHENTICATED' then raise; end if; end;
  perform set_config('request.jwt.claim.sub',actor::text,true);
  update public.app_users set is_active=false where id=actor;
  begin perform public.get_report_user_markets(); raise exception 'Disabled staff accepted'; exception when others then if sqlerrm<>'USER_DISABLED' then raise; end if; end;
  update public.app_users set is_active=true where id=actor;
  if has_function_privilege('anon','public.get_report_user_markets()','EXECUTE') then raise exception 'Anon has execute permission'; end if;
  if not has_function_privilege('authenticated','public.get_report_user_markets()','EXECUTE') then raise exception 'Staff RPC permission missing'; end if;
  if has_function_privilege('authenticated','public.create_linked_field_user(uuid,uuid,text,text,text,jsonb,jsonb)','EXECUTE') then raise exception 'Authenticated can bypass service'; end if;
  if not has_function_privilege('service_role','public.create_linked_field_user(uuid,uuid,text,text,text,jsonb,jsonb)','EXECUTE') then raise exception 'Service permission missing'; end if;
  raise notice 'PASS: supervisor scope, anonymous/field/disabled-staff rejection and RPC grants';
  select id into target from public.market_test_actors where kind='new';
  before_count:=(select count(*) from public.app_users);
  foreach v_role in array array['PROMOTER','TSE','MER'] loop
    for v_value in select value from jsonb_array_elements('[null,""," \t\n ",123,{},[]]'::jsonb) loop
      payload:=jsonb_build_object('designation',v_role,'market',v_value);
      begin
        perform public.create_linked_field_user(actor,target,'new-local','Synthetic onboarding','local-'||v_role,'{}',payload);
        raise exception 'Invalid Market accepted';
      exception when others then if sqlerrm<>'Market is required for new field users' then raise; end if; end;
    end loop;
  end loop;
  if (select count(*) from public.app_users)<>before_count or exists(select 1 from public.promoters where user_id=target) or exists(select 1 from public.org_people where auth_user_id=target) then raise exception 'Failed create left partial records'; end if;
  raise notice 'PASS: missing/blank/non-text Market rejected for all field roles with no partial records';
  foreach v_role in array array['PROMOTER','TSE','MER'] loop
    target:=gen_random_uuid();
    insert into auth.users(id,email) values(target,target::text||'@local.invalid');
    result:=public.create_linked_field_user(actor,target,'local-new-'||v_role,'Synthetic onboarding',target::text,'{}',jsonb_build_object('designation',v_role,'market','  New Market  ','state','Maharashtra'));
    if not exists(select 1 from public.org_people where auth_user_id=target and designation=v_role and market_raw='New Market') then raise exception 'New Market not saved'; end if;
    if not exists(select 1 from jsonb_array_elements(public.get_report_user_markets()) r where r->>'user_id'=target::text and r->>'market'='New Market') then raise exception 'New user Market not reported'; end if;
  end loop;
  target:=gen_random_uuid();
  insert into auth.users(id,email) values(target,target::text||'@local.invalid');
  insert into public.org_people(designation,employee_name,mobile,source_key,source_system,state_raw,market_raw) values('TSE','Synthetic imported person','local-linked-mobile','LOCAL-LINKED','admin','Maharashtra','Original imported City') returning id into org_id;
  perform public.create_linked_field_user(actor,target,'local-linked','Synthetic linked user','local-linked-mobile','{}',jsonb_build_object('designation','TSE','person_id',org_id,'market','Correct Market'));
  if not exists(select 1 from public.org_people where id=org_id and auth_user_id=target and market_raw='Original imported City' and market_override='Correct Market') then raise exception 'Linked Market override not saved or original geography lost'; end if;
  raise notice 'PASS: new Promoter/TSE/MER and linked-person creation save Market and preserve imported raw geography';
end $$;
