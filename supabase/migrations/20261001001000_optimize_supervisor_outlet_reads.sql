-- Keep supervisor outlet visibility identical while avoiding a nested
-- per-outlet, per-promoter call to promoter_user_can_access_outlet().
create or replace function public.supervisor_can_access_outlet(p_outlet_id uuid)
returns boolean
language sql stable security definer set search_path=public as $$
  select exists (
    select 1
    from public.outlets o
    join public.promoters pr on pr.supervisor_id=auth.uid()
    join public.org_people p on p.auth_user_id=pr.user_id
      and p.designation='PROMOTER' and p.active
    where o.id=p_outlet_id and o.status='active'
      and (
        (p.outlet_access_mode='workbook_exact' and exists (
          select 1 from public.promoter_outlet_workbook_assignments a
          where a.promoter_id=p.id and a.outlet_id=o.id and a.source_state='UTTAR PRADESH'
        ))
        or (p.outlet_access_mode is distinct from 'workbook_exact' and (
          exists (
            select 1 from public.promoter_outlet_assignments a
            where a.promoter_id=p.id and a.outlet_id=o.id and a.active
          )
          or (p.outlet_access_mode='workbook_additive' and exists (
            select 1 from public.promoter_outlet_workbook_assignments a
            where a.promoter_id=p.id and a.outlet_id=o.id and a.source_state='UTTAR PRADESH'
          ))
          or exists (
            select 1
            from (
              select a.mer_id from public.promoter_mer_assignments a where a.promoter_id=p.id
              union select p.mapped_mer_id where p.mapped_mer_id is not null
            ) mapped
            join public.org_people m on m.id=mapped.mer_id and m.designation='MER' and m.active
            cross join lateral jsonb_array_elements_text(
              coalesce(m.beat_override,m.beat_values,'[]'::jsonb)
            ) beat(value)
            where public.org_match_key(beat.value)=public.org_match_key(o.beat)
              and public.org_match_key(o.beat)<>''
          )
        ))
      )
  );
$$;

create or replace function public.supervisor_can_access_tse(p_tse_id uuid)
returns boolean
language sql stable security definer set search_path=public as $$
  select exists (
    select 1 from public.outlets o
    where o.tse_id=p_tse_id and o.status='active'
      and public.supervisor_can_access_outlet(o.id)
  );
$$;

drop policy if exists outlets_read on public.outlets;
create policy outlets_read on public.outlets for select to authenticated using (
  public.is_admin()
  or (public.my_role()='promoter' and public.promoter_user_can_access_outlet(auth.uid(),outlets.id))
  or (public.my_role()='supervisor' and public.supervisor_can_access_outlet(outlets.id))
);

drop policy if exists tses_read on public.tses;
create policy tses_read on public.tses for select to authenticated using (
  public.is_admin()
  or (public.my_role()='promoter' and exists (
    select 1 from public.outlets o where o.tse_id=tses.id
      and public.promoter_user_can_access_outlet(auth.uid(),o.id)
  ))
  or (public.my_role()='supervisor' and public.supervisor_can_access_tse(tses.id))
);

revoke all on function public.supervisor_can_access_outlet(uuid) from public,anon;
revoke all on function public.supervisor_can_access_tse(uuid) from public,anon;
grant execute on function public.supervisor_can_access_outlet(uuid) to authenticated;
grant execute on function public.supervisor_can_access_tse(uuid) to authenticated;
