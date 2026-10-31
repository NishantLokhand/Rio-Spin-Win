-- Read only. Run after the two enrollment scripts; Harshraj is never modified.
with requested(name, expected_speakers) as (values
  ('TUSHAR SURESH AMRUTKAR', null::integer),
  ('ASHISH RAMU KALWAL', 10),
  ('SUJAL KALIDAS WANKHEDE', 10),
  ('HARSHRAJ SHELAR', 20)
)
select r.name as requested_name, count(u.id) over(partition by r.name) as account_matches,
  u.id as user_id, u.full_name, u.login_id, u.is_active,
  public._v7_distribution_mode(u.id) as effective_v7_category,
  o.starts_on as v7_starts_on, o.expires_on as v7_expires_on,
  m.enabled as selected_for_v8, m.reported_speakers,
  public._v8_user_enabled(c.id,u.id) as v8_effective,
  r.expected_speakers, i.on_hand as speaker_stock, i.reserved as speaker_reserved,
  i.on_hand-i.reserved as speakers_available,
  (select public._available(u.id,p.id) from public.prizes p where p.code='SNACK10') as snack10_available,
  (select public._available(u.id,p.id) from public.prizes p where p.code='SHADES') as shades_available
from requested r
left join public.app_users u on regexp_replace(upper(u.full_name),'[^A-Z0-9]','','g')=
  regexp_replace(upper(r.name),'[^A-Z0-9]','','g')
left join public.prize_user_distribution_overrides o on o.user_id=u.id
left join public.prize_v8_users m on m.user_id=u.id
left join public.campaigns c on c.code='RSW-2026'
left join public.prizes p on p.code='SPEAKER'
left join public.promoter_inventory i on i.promoter_id=u.id and i.prize_id=p.id
order by r.name,u.id;
