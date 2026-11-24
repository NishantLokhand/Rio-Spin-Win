-- New isolated daily follow-up report only. Existing reports, prize draws and stock are untouched.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';
create or replace function public.report_less_than_ten_spins(p_date date default public.ist_today()-1)
returns jsonb language plpgsql stable security definer set search_path=public as $report$
declare actor public.app_users; is_service boolean:=coalesce(auth.role()='service_role',false); result jsonb;
begin
  if not is_service then actor:=public._require_staff();end if;
  if p_date is null or p_date>public.ist_today() then raise exception 'Choose today or an earlier report date';end if;
  with master(login_id,promoter_code,market) as (values
      ('8090244243', 'TSE-8090244243', 'VARANASI'),
      ('8953357289', 'STAFF-8953357289', 'RAEBARELI'),
      ('6393661249', 'STAFF-6393661249', 'SITAPUR'),
      ('8318968669', 'STAFF-8318968669', 'LUCKNOW'),
      ('9892767290', 'STAFF-9892767290', 'THANE'),
      ('9975002258', 'STAFF-9975002258', 'THANE'),
      ('9450770247', 'STAFF-9450770247', 'RAEBARELI'),
      ('9822942123', 'STAFF-9822942123', 'NAGPUR'),
      ('7276067510', 'PROMOTER-d8bc0313-2ba1-4c0a-b23d-4704c5136bfa', 'NANDED'),
      ('9415152180', 'STAFF-9415152180', 'SITAPUR'),
      ('8853995804', 'STAFF-8853995804', 'SITAPUR'),
      ('7388314002', 'STAFF-7388314002', 'LUCKNOW'),
      ('7571011177', 'MER-28c0a09e-789e-44bc-ad0e-80adea9b9860', 'KANPUR'),
      ('7905896464', 'PROMOTER-310c66fb-9dbf-47ea-b76f-8b08d2d5faf3', 'KANPUR'),
      ('8004897852', 'STAFF-8004897852', 'KANPUR'),
      ('7754980903', 'STAFF-7754980903', 'LUCKNOW'),
      ('7906322161', 'STAFF-7906322161', 'SAHARANPUR'),
      ('9648940001', 'STAFF-9648940001', 'SULTANPUR'),
      ('9455764143', 'STAFF-9455764143', 'VARANASI'),
      ('9511701044', 'PROMOTER-1eb1f1d1-e585-494a-9753-c4d8cf2ef4b2', 'SOLAPUR'),
      ('9639043630', 'PROMOTER-cd9b636d-de53-4bab-a028-19f2ed697eda', 'MORADABAD'),
      ('9766014354', 'STAFF-9766014354', 'NANDED'),
      ('8208284020', 'STAFF-8208284020', 'NASHIK'),
      ('9890450300', 'PROMOTER-5761e2a4-31fa-4db2-b755-ab53395d41d4', 'AHMEDNAGAR'),
      ('7248236855', 'PROMOTER-e32d9861-d44b-4010-9ee6-7376dd984ba7', 'NOIDA'),
      ('9881275456', 'STAFF-9881275456', 'THANE'),
      ('8287157810', 'PROMOTER-e5666bb2-61d8-41ac-b31b-e706e5d43699', 'NOIDA'),
      ('6398645835', 'STAFF-6398645835', 'NOIDA'),
      ('9910858695', 'STAFF-9910858695', 'UNNAO'),
      ('9648934145', 'PROMOTER-1a161a9d-7f83-43fe-8f8e-07950dbd7fae', 'PRAYAGRAJ'),
      ('7037572824', 'PROMOTER-abd3cae0-b497-48c7-a4ab-ec010a65d4f8', 'NOIDA'),
      ('7007638065', 'PROMOTER-fe228555-aed2-41ae-97ac-a5176167de6e', 'SULTANPUR'),
      ('9792749410', 'MER-9792749410', 'VARANASI'),
      ('8299600180', 'PROMOTER-d648038e-a554-46f6-8d5c-ac8f6e77b285', 'LUCKNOW'),
      ('8630228196', 'PROMOTER-b9ba7414-b7dd-4304-9a44-e78a28df53ba', 'BAREILLY'),
      ('7668117118', 'PROMOTER-6e9c91df-505b-4442-85a5-a01ac0b86562', 'GHAZIABAD'),
      ('9795191559', 'STAFF-9795191559', 'VARANASI'),
      ('7518891392', 'STAFF-7518891392', 'GORAKHPUR'),
      ('7080095794', 'PROMOTER-234899c3-a776-44e0-b883-cadb9674f49f', 'UNNAO'),
      ('8077577791', 'PROMOTER-1a06e5ed-8afc-4a82-8c85-344a19dce93b', 'ALIGARH'),
      ('8171538502', 'PROMOTER-c8bf3237-a2c2-4122-b816-c5a764f90530', 'NOIDA'),
      ('8624052121', 'STAFF-8624052121', 'AHMEDNAGAR'),
      ('8726583470', 'PROMOTER-aef0fed1-d8bf-46cc-b044-61ddd3a3eee6', 'GHAZIPUR'),
      ('9719207158', 'PROMOTER-d7fc96bc-8563-4a1b-866c-1a76da7061ea', 'AGRA'),
      ('9665333773', 'PROMOTER-f3fcf202-17d7-4a05-92fd-973bff8a7ea4', 'AURANGABAD'),
      ('9021153781', 'STAFF-9021153781', 'CHANDRAPUR'),
      ('9026540850', 'PROMOTER-8f972394-171d-41ae-a18b-762027638f03', 'FATEHPUR'),
      ('9696452723', 'STAFF-9696452723', 'LUCKNOW'),
      ('9897981541', 'STAFF-9897981541', 'MORADABAD'),
      ('6386180587', 'STAFF-6386180587', 'LUCKNOW'),
      ('6306488259', 'STAFF-6306488259', 'SITAPUR'),
      ('9721686728', 'PROMOTER-9c7fb447-3911-481d-889d-60f9382bf289', 'PRAYAGRAJ'),
      ('8384844036', 'PROMOTER-8a3e427e-aa20-4ee8-9bac-fc7cc311a409', 'AGRA'),
      ('7823878311', 'PROMOTER-eb84f8c8-10b8-4269-b041-b12cc4c7c0e3', 'NASHIK'),
      ('8630797917', 'STAFF-8630797917', 'MEERUT'),
      ('7518760101', 'STAFF-7518760101', 'LUCKNOW'),
      ('9892757695', 'STAFF-9892757695', 'MUMBAI'),
      ('7317003781', 'PROMOTER-67c2e8b9-35fa-44ca-94a6-e5d9ae1cce34', 'KHERI'),
      ('9921114438', 'STAFF-9921114438', 'NAGPUR'),
      ('9923543907', 'TSE-c5bba033-df06-4bd0-ae81-e9445352b6b5', 'NASHIK'),
      ('9760373112', 'PROMOTER-ad0d5325-e491-4627-8a77-516524c9eed0', 'NOIDA'),
      ('7309207610', 'STAFF-7309207610', 'LUCKNOW'),
      ('9311874203', 'STAFF-9311874203', 'GHAZIABAD'),
      ('8433094341', 'STAFF-8433094341', 'MORADABAD'),
      ('8081474567', 'STAFF-8081474567', 'PRAYAGRAJ'),
      ('9559710109', 'STAFF-9559710109', 'SHAHJHANPUR'),
      ('9561949982', 'PROMOTER-619ae3ad-abbf-49a1-a052-02ebcf2bd46e', 'BEED'),
      ('9026856404', 'STAFF-9026856404', 'LUCKNOW'),
      ('8208045439', 'STAFF-8208045439', 'PUNE'),
      ('7080995563', 'STAFF-7080995563', 'LUCKNOW'),
      ('8090658065', 'STAFF-8090658065', 'UNNAO'),
      ('8923323913', 'PROMOTER-7ba3df32-a054-4d30-aa57-ee3f3a82d683', 'ALIGARH'),
      ('9368242109', 'PROMOTER-4a5e0e24-a81a-427e-91fb-0b6b0df9d177', 'ALIGARH'),
      ('7275281856', 'STAFF-7275281856', 'RAEBARELI'),
      ('9004491690', 'STAFF-9004491690', 'MUMBAI'),
      ('9917637076', 'STAFF-9917637076', 'BAREILLY'),
      ('7355728937', 'PROMOTER-d5418857-e3d0-428e-91de-55e702c0a2a2', 'KANPUR'),
      ('8009914367', 'STAFF-8009914367', 'SITAPUR'),
      ('9763652771', 'STAFF-9763652771', 'SATARA'),
      ('8840447790', 'PROMOTER-81dbfab6-295c-42e5-8937-1856e2474bcd', 'AMETHI'),
      ('9170459961', 'PROMOTER-7f9c6e3a-e262-460a-b43b-d5d820a2b1f7', 'LUCKNOW'),
      ('9621541970', 'STAFF-9621541970', 'KANPUR'),
      ('9028501053', 'STAFF-9028501053', 'BEED'),
      ('8928255521', 'PROMOTER-7bec9ac4-7cfe-427d-a909-720ba710159a', 'NANDED'),
      ('8948146534', 'STAFF-8948146534', 'UNNAO'),
      ('9984688733', 'STAFF-9984688733', 'PRAYAGRAJ'),
      ('6394509349', 'STAFF-6394509349', 'LUCKNOW'),
      ('8171145048', 'STAFF-8171145048', 'BAREILLY'),
      ('7668254857', 'PROMOTER-3e0c61f5-8309-48c4-9de6-146aa04d26a4', 'ALIGARH'),
      ('9027793116', 'PROMOTER-281e3fe5-81e2-42bf-90f8-d8960fc64d42', 'GHAZIABAD'),
      ('7507738303', 'STAFF-7507738303', 'YAVATMAL'),
      ('7081540188', 'PROMOTER-1867d303-6470-4b2a-aa12-9fbfb41acbbd', 'LUCKNOW'),
      ('7678687164', 'PROMOTER-6d9fec52-399c-4c8c-8c5d-7ece0032b05f', 'NOIDA'),
      ('7007567989', 'STAFF-7007567989', 'KANPUR'),
      ('8318789160', 'PROMOTER-7067f93e-e41d-475d-b812-a1ebc7b69c4f', 'PRAYAGRAJ'),
      ('8630513142', 'PROMOTER-bbe4f73f-4060-4fc0-8fec-2bbe8d2bb8b5', 'AGRA'),
      ('7905616448', 'PROMOTER-88938af8-754e-4dc6-831c-48478e54a2a1', 'RAEBARELI'),
      ('8329325321', 'PROMOTER-d3e8dca0-17a9-468e-a15a-d387690dea03', 'NANDURBAR'),
      ('9762910012', 'STAFF-9762910012', 'BAREILLY'),
      ('9588641384', 'STAFF-9588641384', 'NAGPUR'),
      ('9702308233', 'TSE-b42453ec-b6cc-4b35-83b3-5d674ceed20e', 'MUMBAI'),
      ('8853120920', 'STAFF-8853120920', 'LUCKNOW'),
      ('9569552366', 'STAFF-9569552366', 'THANE'),
      ('8208291347', 'STAFF-8208291347', 'KOLHAPUR'),
      ('8788349319', 'PROMOTER-fd5ec59c-7019-48ef-b010-4cb78ecf0a99', 'AURANGABAD'),
      ('8604987218', 'PROMOTER-6cda28ef-7163-4b19-9fda-3034d56cd73c', 'LUCKNOW'),
      ('9860837007', 'STAFF-9860837007', 'PUNE'),
      ('9082483513', 'MH-TSE-9082483513', 'MUMBAI'),
      ('8805568714', 'STAFF-8805568714', 'YAVATMAL'),
      ('7906090992', 'STAFF-7906090992', 'BULANDSHAHAR'),
      ('9096039881', 'STAFF-9096039881', 'MUMBAI'),
      ('8433415957', 'STAFF-8433415957', 'BAREILLY'),
      ('8960866421', 'MER-e855e494-b6fb-423e-9dba-1c3df007ffac', 'FATEHPUR'),
      ('9881823114', 'STAFF-9881823114', 'KOLHAPUR'),
      ('9118728314', 'UTT-MER-44A8B9F722', 'JAUNPUR'),
      ('9794989299', 'STAFF-9794989299', 'UNNAO'),
      ('8726384596', 'STAFF-8726384596', 'UNNAO'),
      ('9795210043', 'STAFF-9795210043', 'PRATAPGARH'),
      ('9322221958', 'PROMOTER-cfd3ae01-11a5-4d66-8ce9-7e8f2191d030', 'NANDED'),
      ('9198073416', 'STAFF-9198073416', 'GORAKHPUR'),
      ('8421191526', 'STAFF-8421191526', 'AURANGABAD'),
      ('9161905336', 'UP-PROMO-9161905336', 'SITAPUR'),
      ('7007393635', 'PROMOTER-ec510f52-66a2-458c-b6ff-ea53db9c6d88', 'LUCKNOW'),
      ('7900072115', 'PROMOTER-9e6d750d-5c30-4d3e-8cf2-7e545dae284c', 'PRAYAGRAJ'),
      ('9325155758', 'PROMOTER-47e608b4-fcd7-43e1-889f-52ed43eb5f92', 'NANDED'),
      ('9284091371', 'STAFF-9284091371', 'NANDURBAR'),
      ('7355731401', 'PROMOTER-68d8dfaa-708d-4ecf-a237-18a90fe04734', 'AZAMGARH'),
      ('6392304061', 'STAFF-6392304061', 'PRAYAGRAJ'),
      ('7388711348', 'STAFF-7388711348', 'KANPUR'),
      ('6398077228', 'PROMOTER-ba7d5e89-d01d-4511-b796-9ec86818987d', 'NOIDA'),
      ('6397823860', 'STAFF-6397823860', 'MORADABAD'),
      ('7078757390', 'PROMOTER-6bea93de-cc80-4528-8b6c-051e4c2bf733', 'GHAZIABAD'),
      ('9718005121', 'PROMOTER-252f0a15-2ad4-483a-bfb9-8deaa0f9158b', 'NOIDA'),
      ('7300918318', 'STAFF-7300918318', 'MORADABAD'),
      ('9422958273', 'PROMOTER-6a43d5bd-2b41-45f4-b871-be3fc4475de1', 'NANDED'),
      ('9764543143', 'STAFF-9764543143', 'PUNE'),
      ('9309519050', 'PROMOTER-aefb14b9-883e-4fdd-9e42-096648e7b49a', 'CHANDRAPUR'),
      ('8423039039', 'PROMOTER-93a011ac-0ec1-47a8-bda8-80e1f9e6b15d', 'UNNAO'),
      ('7400362469', 'PROMOTER-b753df88-a9b1-4e52-af29-b6c3c0a65474', 'VARANASI'),
      ('8423121049', 'STAFF-8423121049', 'GHAZIPUR'),
      ('8707344539', 'STAFF-8707344539', 'GORAKHPUR'),
      ('9158355958', 'STAFF-9158355958', 'AMRAVATI'),
      ('7800888231', 'STAFF-7800888231', 'GORAKHPUR'),
      ('7558214599', 'STAFF-7558214599', 'KOLHAPUR'),
      ('7054812173', 'STAFF-7054812173', 'PRAYAGRAJ'),
      ('8572990947', 'PROMOTER-b86f1678-d874-4089-ae1a-0730ccac2d2f', 'JAUNPUR'),
      ('7080162881', 'STAFF-7080162881', 'LUCKNOW'),
      ('8957634514', 'STAFF-8957634514', 'PRAYAGRAJ'),
      ('9284646970', 'PROMOTER-c01bdec7-f69f-4370-9b80-ff2591c7e2fd', 'AMRAVATI'),
      ('9628454209', 'PROMOTER-4df0ed96-5bf2-4d59-8ade-8501c04e5032', 'AYODHYA'),
      ('8788547475', 'STAFF-8788547475', 'AHMEDNAGAR'),
      ('8859303502', 'STAFF-8859303502', 'MORADABAD'),
      ('8953637362', 'STAFF-8953637362', 'LUCKNOW'),
      ('9305764109', 'PROMOTER-9b7dd4f9-b669-425d-bed8-9e0ec34aad80', 'KHERI'),
      ('8999803453', 'PROMOTER-6753547e-e15a-4a0c-a08e-301f7d4face1', 'NANDED'),
      ('9125687131', 'STAFF-9125687131', 'ALIGARH'),
      ('9889734718', 'STAFF-9889734718', 'SITAPUR'),
      ('9794625321', 'PROMOTER-79bbd66b-779d-4a4a-8561-3fdcad3a9fb6', 'PRAYAGRAJ'),
      ('9373290743', 'STAFF-9373290743', 'SOLAPUR'),
      ('9210807535', 'PROMOTER-661019cf-466e-424d-b2c4-9d5317f13232', 'GORAKHPUR'),
      ('75052 39972', 'PROMOTER-9f990e13-8ec8-4c71-98e0-9dd0eeda9133', 'GHAZIABAD'),
      ('9730401699', 'STAFF-9730401699', 'KOLHAPUR'),
      ('7895285779', 'STAFF-7895285779', 'BIJNORE'),
      ('6394564198', 'STAFF-6394564198', 'BAHRAICH'),
      ('8286897190', 'TSE-01b46966-0d13-4df4-859a-563fbc18ed85', 'THANE'),
      ('9022274076', 'STAFF-9022274076', 'CHANDRAPUR'),
      ('8767373493', 'PROMOTER-4edfd8c3-803c-4b9d-8072-03e5d2f87059', 'CHANDRAPUR'),
      ('8429357213', 'STAFF-8429357213', 'BAREILLY'),
      ('9452887752', 'PROMOTER-fbf0b48c-50e7-4542-93d1-f5fd6f6c7696', 'VANARASI'),
      ('8793607321', 'STAFF-8793607321', 'PUNE'),
      ('9082383301', 'STAFF-9082383301', 'MUMBAI'),
      ('9423051032', 'STAFF-9423051032', 'SOLAPUR'),
      ('8329843007', 'STAFF-8329843007', 'AKOLA'),
      ('8191969809', 'PROMOTER-add8df38-8053-4cf0-9733-039e24a9cdb8', 'ALIGARH'),
      ('9457166077', 'STAFF-9457166077', 'BAREILLY'),
      ('6307909420', 'PROMOTER-3f8db9cc-08bb-41af-894b-2128a3127f6a', 'LUCKNOW'),
      ('9545936236', 'PROMOTER-0be6a1af-6d85-4e6e-8f44-493baf933e73', 'NANDURBAR'),
      ('8329503829', 'STAFF-8329503829', 'NASHIK'),
      ('7057577999', 'PROMOTER-0f18a631-dea6-48fe-b0ee-0a6f727f26ce', 'NANDURBAR'),
      ('9130121612', 'PROMOTER-8f0f4549-230c-4133-956d-3c2f4b19a5cb', 'AKOLA'),
      ('8303590544', 'STAFF-8303590544', 'KANPUR'),
      ('9175326637', 'PROMOTER-6b8a773a-fcbd-410d-9e3a-5ca931b40f7c', 'BEED'),
      ('9054124917', 'STAFF-9054124917', 'MUMBAI'),
      ('9310561044', 'PROMOTER-7082fb8c-1513-491b-ad09-49bc86792ae0', 'NOIDA'),
      ('9370498358', 'PROMOTER-c507309d-6a29-42c9-9023-2a35edfa2726', 'AURANGABAD'),
      ('8177871864', 'STAFF-8177871864', 'JALGAON'),
      ('8840669248', 'STAFF-8840669248', 'GORAKHPUR'),
      ('8279834097', 'STAFF-8279834097', 'NASHIK'),
      ('9837086668', 'UP-TSE-9837086668', 'AGRA'),
      ('9175527019', 'STAFF-9175527019', 'AHMEDNAGAR'),
      ('8851203657', 'STAFF-8851203657', 'ALIGARH'),
      ('9719062563', 'PROMOTER-150d8767-56ba-47d8-8d1d-81e2f1bd451f', 'MUZAFFARNAGAR'),
      ('8707373490', 'PROMOTER-992c2285-1303-4cbc-90bb-917e44b7f63b', 'VARANASI'),
      ('9990291540', 'STAFF-9990291540', 'GHAZIABAD'),
      ('8960991733', 'STAFF-8960991733', 'VARANASI'),
      ('9891007561', 'PROMOTER-00a3f609-43ea-4ad6-b3ef-838a38addce6', 'NOIDA'),
      ('7276028438', 'STAFF-7276028438', 'THANE'),
      ('9286651987', 'PROMOTER-9e233dbd-45b1-460f-bceb-9d5dcb3e8b5c', 'ALIGARH'),
      ('9970553314', 'STAFF-9970553314', 'NANDURBAR'),
      ('9075021313', 'STAFF-9075021313', 'AURANGABAD'),
      ('9096333059', 'STAFF-9096333059', 'JALGAON'),
      ('9519868945', 'MER-db7c12d1-225e-44d8-8ed6-97817dfebda1', 'BARABANKI')
  ), eligible as materialized (
    select u.id,u.full_name,u.login_id,coalesce(nullif(op.mobile,''),nullif(u.mobile,''),u.login_id) as mobile,
      p.promoter_code,
      case op.designation when 'PROMOTER' then 'Promoter' when 'TSE' then 'TSE' when 'MER' then 'MER' else 'Unknown' end as user_type,
      coalesce(lm.market,cm.market,nullif(op.market_override,''),nullif(op.market_raw,''),'Unassigned') as market,
      case regexp_replace(upper(coalesce(nullif(op.state_raw,''),st.name,'')),'[^A-Z]','','g')
        when 'MH' then 'Maharashtra' when 'MAHARASHTRA' then 'Maharashtra' when 'MAHARASHTRAROM' then 'Maharashtra'
        when 'UP' then 'Uttar Pradesh' when 'UTTARPRADESH' then 'Uttar Pradesh'
        else coalesce(nullif(btrim(op.state_raw),''),st.name,'Unassigned') end as state,
      coalesce(op.market_override,op.market_raw,'') as city,coalesce(op.area_override,op.area_raw,'') as area,
      (u.created_at at time zone 'Asia/Kolkata')::date as account_date
    from public.app_users u left join public.promoters p on p.user_id=u.id
    left join public.states st on st.id=p.home_state_id
    left join lateral(select o.* from public.org_people o where o.auth_user_id=u.id order by o.id limit 1)op on true
    left join master lm on lm.login_id=btrim(u.login_id)
    left join master cm on cm.promoter_code=btrim(p.promoter_code)
    where u.role='promoter' and u.is_active
      and (is_service or actor.role='admin' or p.supervisor_id=actor.id)
      and (u.created_at at time zone 'Asia/Kolkata')::date<=p_date
      and not exists(select 1 from public.deleted_field_users d where d.user_id=u.id)
      and not (u.id=any(public._report_excluded_user_ids()))
      and u.login_id !~* '^(test|demo)([^a-z]|$)'
      and u.full_name !~* '(^|[^a-z0-9])(test|demo)([^a-z]|$)'
      and u.login_id<>'9876500002' and lower(regexp_replace(btrim(u.full_name),'\s+',' ','g'))<>'sneha yadav'
  ), daily as materialized (
    select e.*,count(sp.id)::integer as spins,min(sp.created_at) as first_spin_at,max(sp.created_at) as last_spin_at,
      coalesce(sum(sp.prize_cost) filter(where sp.redemption_status<>'not_redeemed'),0) as giveaway_cost,
      count(sp.id) filter(where sp.prize_code='SNACK5') as snack5,
      count(sp.id) filter(where sp.prize_code='SNACK10') as snack10,
      count(sp.id) filter(where sp.prize_code='SHADES') as shades,
      count(sp.id) filter(where sp.prize_code='SPEAKER') as speakers,
      count(sp.id) filter(where sp.prize_code not in ('SNACK5','SNACK10','SHADES','SPEAKER')) as other_prizes
    from eligible e left join public.spins sp on sp.promoter_id=e.id and sp.biz_date=p_date
    group by e.id,e.full_name,e.login_id,e.mobile,e.promoter_code,e.user_type,e.market,e.state,e.city,e.area,e.account_date
  ), detail as (
    select d.id::text||':'||p_date::text as id,d.id as key,p_date as date,d.full_name as label,d.user_type,d.market,d.state,d.city,d.area,
      d.login_id as login,d.mobile,d.promoter_code as user_code,d.account_date,'Active'::text as account_status,
      d.spins,coalesce(vis.units,0) as units,coalesce(vis.active_outlets,0) as active_outlets,coalesce(vis.outlets,'') as outlets,
      d.giveaway_cost,case when d.spins>0 then round(d.giveaway_cost/d.spins,2) else 0 end as avg_cost,
      coalesce(to_char(d.first_spin_at at time zone 'Asia/Kolkata','HH24:MI:SS'),'N/A') as first_spin_time,
      coalesce(to_char(d.last_spin_at at time zone 'Asia/Kolkata','HH24:MI:SS'),'N/A') as last_spin_time,
      case when d.spins=0 then '0h 00m' else
        (floor(extract(epoch from d.last_spin_at-d.first_spin_at)/3600))::text||'h '||
        lpad((floor(extract(epoch from d.last_spin_at-d.first_spin_at)/60)::int%60)::text,2,'0')||'m' end as activity_span,
      concat_ws(' · ',case when d.snack5>0 then '₹5 Snack: '||d.snack5 end,
        case when d.snack10>0 then '₹10 Snack: '||d.snack10 end,case when d.shades>0 then 'Rio Shades: '||d.shades end,
        case when d.speakers>0 then 'Speaker: '||d.speakers end,case when d.other_prizes>0 then 'Other: '||d.other_prizes end) as prizes_given,
      case when p_date<public.ist_today() and d.spins>0 then 1 else 0 end as active_days,
      case when p_date<public.ist_today() and d.spins=0 then 1 else 0 end as no_spin_days,
      case when p_date<public.ist_today() then case when d.spins>0 then 100 else 0 end end as activity_pct,
      stock.snack5_used_pct,stock.snack10_used_pct,
      d.snack5,d.snack10,d.shades,d.speakers,
      case when d.spins=0 then 'No spins recorded' else 'Below 10 spins' end as activity,
      p_date as date_from,p_date as date_to
    from daily d
    left join lateral (
      select sum(s.quantity) as units,count(distinct s.outlet_id) as active_outlets,
        string_agg(distinct coalesce(s.outlet_name,'Unnamed outlet')||' ['||coalesce(s.outlet_code,s.outlet_id::text)||']','; '
          order by coalesce(s.outlet_name,'Unnamed outlet')||' ['||coalesce(s.outlet_code,s.outlet_id::text)||']') as outlets
      from public.report_sales_resolved s where s.promoter_id=d.id and s.biz_date=p_date and s.status<>'cancelled'
    )vis on true
    left join lateral (
      select max(case when pr.code='SNACK5' and rec.qty>0 and inv.on_hand<=rec.qty then round(100.0*(rec.qty-inv.on_hand)/rec.qty,2) end) as snack5_used_pct,
        max(case when pr.code='SNACK10' and rec.qty>0 and inv.on_hand<=rec.qty then round(100.0*(rec.qty-inv.on_hand)/rec.qty,2) end) as snack10_used_pct
      from public.prizes pr left join public.promoter_inventory inv on inv.promoter_id=d.id and inv.prize_id=pr.id
      left join lateral(select sum(m.qty) as qty from public.inventory_movements m where m.promoter_id=d.id and m.prize_id=pr.id and m.qty>0)rec on true
      where pr.code in ('SNACK5','SNACK10')
    )stock on true
    where d.spins between 0 and 9
  ), states as (
    select state as label,count(*)::int as total_users,count(*) filter(where spins=0)::int as zero_users,
      count(*) filter(where spins between 1 and 9)::int as low_active_users,count(*) filter(where spins<10)::int as below_target,
      count(*) filter(where spins>=10)::int as target_reached,coalesce(sum(spins),0) as spins
    from daily group by state
  ), markets as (
    select state,market as label,count(*)::int as total_users,count(*) filter(where spins=0)::int as zero_users,
      count(*) filter(where spins between 1 and 9)::int as low_active_users,count(*) filter(where spins<10)::int as below_target,
      count(*) filter(where spins>=10)::int as target_reached,coalesce(sum(spins),0) as spins
    from daily group by state,market
  )
  select jsonb_build_object('date',p_date,'timezone','Asia/Kolkata','generated_at',statement_timestamp(),
    'in_progress',p_date=public.ist_today(),
    'summary',(select jsonb_build_object('total_users',count(*),'below_target',count(*) filter(where spins<10),
      'zero_users',count(*) filter(where spins=0),'low_active_users',count(*) filter(where spins between 1 and 9),
      'target_reached',count(*) filter(where spins>=10),'spins',coalesce(sum(spins),0),
      'below_target_pct',case when count(*)>0 then round(100.0*count(*) filter(where spins<10)/count(*),1) else 0 end) from daily),
    'states',coalesce((select jsonb_agg(to_jsonb(s) order by label) from states s),'[]'::jsonb),
    'markets',coalesce((select jsonb_agg(to_jsonb(m) order by below_target desc,state,label) from markets m),'[]'::jsonb),
    'rows',coalesce((select jsonb_agg(to_jsonb(r) order by spins,label,key) from detail r),'[]'::jsonb)
  ) into result;
  return result;
end $report$;
revoke all on function public.report_less_than_ten_spins(date) from public,anon,authenticated,service_role;
grant execute on function public.report_less_than_ten_spins(date) to authenticated,service_role;
comment on function public.report_less_than_ten_spins(date) is
 'Read-only daily 0-9 spin follow-up; current active real field accounts only. Staff scope or service-only scheduled reporting. User geography and recorded visits remain distinct.';
notify pgrst,'reload schema';
commit;
