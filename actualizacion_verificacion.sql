-- =====================================================================
-- CHARRERÍA PRO — Actualización: verificación "Pendiente" / "Oficial" de charros, equipos y caballos
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run.
-- Requiere actualizacion_valuacion.sql. Se puede correr varias veces.
-- =====================================================================

-- 1) Campos de verificación (los escribe solo set_verified) y huella de los datos verificados
create or replace function public.verif_of(d jsonb) returns jsonb
language sql immutable as $$
  select jsonb_build_object('verif', d->'verif', 'verifKey', d->'verifKey', 'verifiedBy', d->'verifiedBy',
    'verifiedByName', d->'verifiedByName', 'verifiedAt', d->'verifiedAt', 'verifNote', d->'verifNote')
$$;
create or replace function public.vk(d jsonb, variadic keys text[]) returns text
language sql immutable as $$
  select string_agg(lower(trim(coalesce(d->>k, ''))), '|' order by i) from unnest(keys) with ordinality as t(k, i)
$$;
-- Debe coincidir con verifKeyOf() de la app
create or replace function public.verif_key(kind text, d jsonb) returns text
language sql immutable as $$
  select case kind
    when 'charro' then public.vk(d, 'name', 'category')
    when 'team'   then public.vk(d, 'name', 'state')
    when 'horse'  then public.vk(d, 'name', 'registry', 'breed', 'training', 'birthYear', 'discipline', 'sex')
  end
$$;

-- 2) Quién puede verificar: súper usuario; o el lienzo verificado sobre charros y equipos afiliados a él
--    y sobre los caballos que corrieron en sus charreadas
create or replace function public.can_verify(kind text, rid text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare lid text; ok boolean := false;
begin
  if public.is_super() then return true; end if;
  if not (public.is_approved() and public.my_data()->>'role' = 'lienzo') then return false; end if;
  lid := public.my_data()->>'lienzoId';
  if not public.owns_lienzo(lid) then return false; end if;
  if kind = 'team' then
    select exists (select 1 from teams t where t.id = rid and t.data->>'lienzoId' = lid and t.data->>'lienzoStatus' = 'aprobado') into ok;
  elsif kind = 'charro' then
    select exists (select 1 from charros c join teams t on t.id = c.data->>'teamId'
                   where c.id = rid and t.data->>'lienzoId' = lid and t.data->>'lienzoStatus' = 'aprobado') into ok;
  elsif kind = 'horse' then
    select exists (select 1 from events e, jsonb_array_elements(e.data->'charros') ch
                   where e.data->>'lienzoId' = lid and ch->>'horseId' = rid) into ok;
  end if;
  return ok;
end $$;

-- decision: 'oficial' | 'rechazado' | 'pendiente' (quitar el sello; solo súper usuario)
create or replace function public.set_verified(kind text, rid text, decision text, note text default '') returns void
language plpgsql security definer set search_path = public as $$
declare tbl text; d jsonb; me jsonb := public.my_data(); now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  tbl := case kind when 'charro' then 'charros' when 'team' then 'teams' when 'horse' then 'horses' end;
  if tbl is null then raise exception 'Tipo inválido'; end if;
  if decision = 'pendiente' and not public.is_super() then raise exception 'No tienes permiso para esta acción'; end if;
  if decision not in ('oficial','rechazado','pendiente') then raise exception 'Decisión inválida'; end if;
  if not public.can_verify(kind, rid) then raise exception 'No tienes permiso para verificar este registro'; end if;
  execute format('select data from %I where id = $1 for update', tbl) into d using rid;
  if d is null then raise exception 'Registro no encontrado'; end if;
  execute format('update %I set data = data || $1 where id = $2', tbl) using jsonb_build_object(
    'verif', decision, 'verifKey', case when decision = 'pendiente' then null else public.verif_key(kind, d) end,
    'verifiedBy', auth.uid()::text, 'verifiedByName', coalesce(me->>'name', ''), 'verifiedAt', now_ms,
    'verifNote', case when decision = 'rechazado' then coalesce(note, '') else '' end), rid;
end $$;
revoke all on function public.set_verified(text, text, text, text) from public, anon;
grant execute on function public.set_verified(text, text, text, text) to authenticated;

-- 3) Nadie se pone el sello solo: altas sin verificación y ediciones que no tocan los campos de verificación
drop policy if exists "charros alta" on public.charros;
create policy "charros alta" on public.charros for insert with check (
  public.is_super() or (charros.data->>'userId' = auth.uid()::text and coalesce(charros.data->>'teamId','') = ''
    and charros.data->'verif' is null and charros.data->'verifKey' is null));
drop policy if exists "charros cambio" on public.charros;
create policy "charros cambio" on public.charros for update
  using (public.is_super() or charros.data->>'userId' = auth.uid()::text)
  with check (public.is_super() or (
    charros.data->>'userId' = auth.uid()::text
    and coalesce(charros.data->>'teamId','') = coalesce((select c.data->>'teamId' from charros c where c.id = charros.id),'')
    and public.verif_of(charros.data) = public.verif_of((select c.data from charros c where c.id = charros.id))));

drop policy if exists "teams alta" on public.teams;
create policy "teams alta" on public.teams for insert with check (
  public.is_super() or (teams.data->>'captainId' = auth.uid()::text
    and coalesce(teams.data->>'lienzoId','') = '' and coalesce(teams.data->>'lienzoStatus','') = ''
    and teams.data->'verif' is null and teams.data->'verifKey' is null));
drop policy if exists "teams cambio" on public.teams;
create policy "teams cambio" on public.teams for update
  using (public.is_super() or teams.data->>'captainId' = auth.uid()::text)
  with check (public.is_super() or (
    teams.data->>'captainId' = auth.uid()::text
    and coalesce(teams.data->>'lienzoId','') = coalesce((select t.data->>'lienzoId' from teams t where t.id = teams.id),'')
    and coalesce(teams.data->>'lienzoStatus','') = coalesce((select t.data->>'lienzoStatus' from teams t where t.id = teams.id),'')
    and public.verif_of(teams.data) = public.verif_of((select t.data from teams t where t.id = teams.id))));

drop policy if exists "horses alta" on public.horses;
create policy "horses alta" on public.horses for insert with check (
  public.is_approved() and horses.data->>'ownerId' = auth.uid()::text
  and jsonb_array_length(coalesce(horses.data->'history', '[]'::jsonb)) = 0
  and coalesce(horses.data->'priceOverride', 'null'::jsonb) = 'null'::jsonb
  and horses.data->'verif' is null and horses.data->'verifKey' is null);
drop policy if exists "horses cambio" on public.horses;
create policy "horses cambio" on public.horses for update
  using (public.is_super() or horses.data->>'ownerId' = auth.uid()::text)
  with check (public.is_super() or (
    horses.data->>'ownerId' = auth.uid()::text
    and coalesce(horses.data->'history', '[]'::jsonb) = coalesce((select h.data->'history' from horses h where h.id = horses.id), '[]'::jsonb)
    and coalesce(horses.data->'priceOverride', 'null'::jsonb) = coalesce((select h.data->'priceOverride' from horses h where h.id = horses.id), 'null'::jsonb)
    and public.verif_of(horses.data) = public.verif_of((select h.data from horses h where h.id = horses.id))));
