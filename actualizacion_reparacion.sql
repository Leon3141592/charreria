-- =====================================================================
-- CHARRERÍA PRO — Actualización: repara perfiles y solicitudes
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run. Se puede correr varias veces.
-- =====================================================================

-- Estas dos reglas se consultaban a sí mismas y Postgres las rechazaba con "infinite recursion".
-- Las comparaciones pasan a funciones que leen la tabla directamente; lo que se permite no cambia.

create or replace function public.profile_same(pid text, d jsonb) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles p where p.id = pid
    and d->>'role' = p.data->>'role' and d->>'status' = p.data->>'status'
    and coalesce(d->>'lienzoId', '') = coalesce(p.data->>'lienzoId', '')
    and coalesce(d->>'verified', 'false') = coalesce(p.data->>'verified', 'false')
    and coalesce(d->>'subscriptionStatus', 'free') = coalesce(p.data->>'subscriptionStatus', 'free')
    and coalesce(d->>'proUntil', '') = coalesce(p.data->>'proUntil', ''))
$$;
revoke all on function public.profile_same(text, jsonb) from public, anon;
grant execute on function public.profile_same(text, jsonb) to authenticated;

drop policy if exists "profiles propio" on public.profiles;
create policy "profiles propio" on public.profiles for update using (id = auth.uid()::text)
  with check (id = auth.uid()::text and public.profile_same(profiles.id, profiles.data));

create or replace function public.req_pending(t text, k text, v text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from requests r where r.data->>'type' = t and r.data->>'status' = 'pendiente' and r.data->>k = v)
$$;
revoke all on function public.req_pending(text, text, text) from public, anon;
grant execute on function public.req_pending(text, text, text) to authenticated;

drop policy if exists "requests alta" on public.requests;
create policy "requests alta" on public.requests for insert with check (
  requests.data->>'createdBy' = auth.uid()::text and requests.data->>'status' = 'pendiente'
  and ( ( requests.data->>'type' = 'roster'
          and exists (select 1 from charros c where c.id = requests.data->>'charroId' and c.data->>'userId' = auth.uid()::text)
          and exists (select 1 from teams t where t.id = requests.data->>'teamId')
          and not public.req_pending('roster', 'charroId', requests.data->>'charroId') )
     or ( requests.data->>'type' = 'afiliacion'
          and exists (select 1 from teams t where t.id = requests.data->>'teamId' and t.data->>'captainId' = auth.uid()::text)
          and exists (select 1 from lienzos l where l.id = requests.data->>'lienzoId' and l.data->>'status' = 'aprobado')
          and not public.req_pending('afiliacion', 'teamId', requests.data->>'teamId') )
     or ( requests.data->>'type' = 'transfer'
          and exists (select 1 from horses h where h.id = requests.data->>'horseId' and h.data->>'ownerId' = auth.uid()::text)
          and length(coalesce(requests.data->>'code', '')) >= 8
          and not public.req_pending('transfer', 'horseId', requests.data->>'horseId') )
     or ( requests.data->>'type' = 'interes'
          and exists (select 1 from horses h where h.id = requests.data->>'horseId' and h.data->>'forSale' = 'true'
                      and h.data->>'ownerId' is distinct from auth.uid()::text) )
     or ( requests.data->>'type' = 'chip_order'
          and ( (requests.data->>'targetKind' = 'horse' and exists (select 1 from horses h where h.id = requests.data->>'targetId' and h.data->>'ownerId' = auth.uid()::text))
             or (requests.data->>'targetKind' = 'stock' and exists (select 1 from stock s where s.id = requests.data->>'targetId' and s.data->>'ownerId' = auth.uid()::text)) )
          and coalesce(requests.data->>'kitUid', '') = '' ) ));

notify pgrst, 'reload schema';
select 'perfiles y solicitudes reparados' as resultado;
