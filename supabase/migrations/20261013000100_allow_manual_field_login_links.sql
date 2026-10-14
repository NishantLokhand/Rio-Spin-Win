-- Support manually created promoter app logins for active TSE and MER profiles.
-- Keep the existing RPC name, admin-only authorization and inventory seeding behavior.
-- Refuse to replace another profile link. This migration does not auto-link accounts.

create or replace function public.link_org_promoter(p_person_id uuid,p_user_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare p public.org_people; u public.app_users; r record; v_prize uuid; v_qty int; v_seeded uuid;
begin
  if not public.is_admin() then raise exception 'ADMIN_ONLY'; end if;
  select * into p from public.org_people where id=p_person_id and designation in ('PROMOTER','MER','TSE') and active for update;
  select * into u from public.app_users where id=p_user_id and role='promoter' for update;
  if p.id is null or u.id is null then raise exception 'PROMOTER_LINK_INVALID'; end if;
  if p.auth_user_id is not null and p.auth_user_id<>p_user_id then
    raise exception 'ORG_PROFILE_ALREADY_LINKED';
  end if;
  if exists(select 1 from public.org_people where auth_user_id=p_user_id and id<>p_person_id) then
    raise exception 'LOGIN_ALREADY_LINKED';
  end if;
  update public.org_people set auth_user_id=p_user_id,updated_at=now() where id=p_person_id;
  for r in select * from public.org_inventory where person_id=p_person_id loop
    for v_prize,v_qty in select pr.id,
      case when pr.code='SNACK5' then r.snack5_initial+coalesce((select sum(qty_delta) from public.org_inventory_adjustments a where a.org_inventory_id=r.id and a.prize_code='SNACK5'),0)
           when pr.code='SNACK10' then r.snack10_initial+coalesce((select sum(qty_delta) from public.org_inventory_adjustments a where a.org_inventory_id=r.id and a.prize_code='SNACK10'),0) end
      from public.prizes pr where pr.code in ('SNACK5','SNACK10') loop
      if v_qty>0 then
        insert into public.promoter_inventory(promoter_id,prize_id,on_hand,reserved) values(p_user_id,v_prize,v_qty,0)
          on conflict(promoter_id,prize_id) do nothing returning promoter_id into v_seeded;
        if v_seeded is not null then
          insert into public.inventory_movements(promoter_id,prize_id,movement_type,qty,on_hand_after,performed_by,reference,note)
          values(p_user_id,v_prize,'issue',v_qty,v_qty,auth.uid(),'org-link:'||p_person_id::text,'Initial source allocation linked to promoter account');
        end if;
        v_seeded:=null;
      end if;
    end loop;
  end loop;
  perform public.write_audit('ORG_PROMOTER_LINK','org_people',p_person_id::text,jsonb_build_object('auth_user_id',p_user_id));
  return jsonb_build_object('ok',true);
end $$;

revoke all on function public.link_org_promoter(uuid,uuid) from public,anon;
grant execute on function public.link_org_promoter(uuid,uuid) to authenticated;
