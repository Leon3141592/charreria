-- =====================================================================
-- CHARRERÍA PRO — Actualización: caballos, cambio de dueño, valuación y vitrina
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run.
-- Requiere actualizacion_perfiles.sql. Se puede correr varias veces.
-- =====================================================================

-- 1) TABLAS
create table if not exists public.horses   (id text primary key, data jsonb not null, created_at timestamptz default now());
create table if not exists public.settings (id text primary key, data jsonb not null, created_at timestamptz default now());
create index if not exists horses_owner_idx on public.horses ((data->>'ownerId'));
alter table public.horses   enable row level security;
alter table public.settings enable row level security;

-- Rango de valuación por omisión (el súper usuario lo cambia desde la app)
insert into public.settings (id, data) values ('valuacion', '{"id":"valuacion","min":60000,"max":800000}'::jsonb)
on conflict (id) do nothing;

-- 2) PERMISOS
-- CABALLOS: lectura pública (el nombre del dueño solo se guarda si él decide mostrarlo).
-- El dueño los registra y edita; nadie puede cambiar de dueño editando, solo con claim_horse()
drop policy if exists "horses lectura" on public.horses;
create policy "horses lectura" on public.horses for select using (true);
drop policy if exists "horses alta" on public.horses;
create policy "horses alta" on public.horses for insert with check (
  public.is_approved() and horses.data->>'ownerId' = auth.uid()::text
  and jsonb_array_length(coalesce(horses.data->'history', '[]'::jsonb)) = 0);
drop policy if exists "horses cambio" on public.horses;
create policy "horses cambio" on public.horses for update
  using (public.is_super() or horses.data->>'ownerId' = auth.uid()::text)
  with check (public.is_super() or (
    horses.data->>'ownerId' = auth.uid()::text
    and coalesce(horses.data->'history', '[]'::jsonb) = coalesce((select h.data->'history' from horses h where h.id = horses.id), '[]'::jsonb)));
drop policy if exists "horses baja" on public.horses;
create policy "horses baja" on public.horses for delete using (public.is_super() or horses.data->>'ownerId' = auth.uid()::text);

-- AJUSTES: lectura pública, solo el súper usuario cambia
drop policy if exists "settings lectura" on public.settings;
create policy "settings lectura" on public.settings for select using (true);
drop policy if exists "settings admin" on public.settings;
create policy "settings admin" on public.settings for all using (public.is_super()) with check (public.is_super());

-- SOLICITUDES: cada quien ve solo las que le tocan (los contactos de compradores solo los ve el dueño del caballo)
drop policy if exists "requests lectura" on public.requests;
create policy "requests lectura" on public.requests for select using (
  public.is_super() or requests.data->>'createdBy' = auth.uid()::text
  or (requests.data->>'type' = 'roster' and public.can_decide_team(requests.data->>'teamId'))
  or (requests.data->>'type' = 'afiliacion' and (public.owns_lienzo(requests.data->>'lienzoId')
      or exists (select 1 from teams t where t.id = requests.data->>'teamId' and t.data->>'captainId' = auth.uid()::text)))
  or (requests.data->>'type' = 'interes'
      and exists (select 1 from horses h where h.id = requests.data->>'horseId' and h.data->>'ownerId' = auth.uid()::text)));

drop policy if exists "requests alta" on public.requests;
create policy "requests alta" on public.requests for insert with check (
  requests.data->>'createdBy' = auth.uid()::text and requests.data->>'status' = 'pendiente'
  and ( ( requests.data->>'type' = 'roster'
          and exists (select 1 from charros c where c.id = requests.data->>'charroId' and c.data->>'userId' = auth.uid()::text)
          and exists (select 1 from teams t where t.id = requests.data->>'teamId')
          and not exists (select 1 from requests r where r.data->>'type' = 'roster' and r.data->>'status' = 'pendiente'
                          and r.data->>'charroId' = requests.data->>'charroId') )
     or ( requests.data->>'type' = 'afiliacion'
          and exists (select 1 from teams t where t.id = requests.data->>'teamId' and t.data->>'captainId' = auth.uid()::text)
          and exists (select 1 from lienzos l where l.id = requests.data->>'lienzoId' and l.data->>'status' = 'aprobado')
          and not exists (select 1 from requests r where r.data->>'type' = 'afiliacion' and r.data->>'status' = 'pendiente'
                          and r.data->>'teamId' = requests.data->>'teamId') )
     or ( requests.data->>'type' = 'transfer'
          and exists (select 1 from horses h where h.id = requests.data->>'horseId' and h.data->>'ownerId' = auth.uid()::text)
          and length(coalesce(requests.data->>'code', '')) >= 8
          and not exists (select 1 from requests r where r.data->>'type' = 'transfer' and r.data->>'status' = 'pendiente'
                          and r.data->>'horseId' = requests.data->>'horseId') )
     or ( requests.data->>'type' = 'interes'
          and exists (select 1 from horses h where h.id = requests.data->>'horseId' and h.data->>'forSale' = 'true'
                      and h.data->>'ownerId' is distinct from auth.uid()::text) ) ));

-- Aprobar, rechazar o cancelar una solicitud (y aplicar el cambio) en un solo paso
create or replace function public.decide_request(rid text, decision text) returns void
language plpgsql security definer set search_path = public as $$
declare r jsonb; me jsonb := public.my_data(); uid text := auth.uid()::text;
begin
  select data into r from requests where id = rid for update;
  if r is null then raise exception 'Solicitud no encontrada'; end if;
  if r->>'status' <> 'pendiente' then raise exception 'Esta solicitud ya fue resuelta'; end if;
  if decision = 'cancelado' then
    if r->>'createdBy' is distinct from uid then raise exception 'No tienes permiso para esta acción'; end if;
  elsif decision in ('aprobado','rechazado') then
    if r->>'type' = 'afiliacion' then
      if not (public.is_super() or public.owns_lienzo(r->>'lienzoId')) then raise exception 'No tienes permiso para esta acción'; end if;
    elsif r->>'type' = 'roster' then
      if not public.can_decide_team(r->>'teamId') then raise exception 'No tienes permiso para esta acción'; end if;
    elsif r->>'type' = 'interes' then
      if not exists (select 1 from horses h where h.id = r->>'horseId' and h.data->>'ownerId' = uid) then raise exception 'No tienes permiso para esta acción'; end if;
    else raise exception 'No tienes permiso para esta acción'; end if;
  else raise exception 'Decisión inválida'; end if;

  update requests set data = data || jsonb_build_object('status', decision, 'decidedBy', uid,
    'decidedByName', coalesce(me->>'name', ''), 'decidedAt', (extract(epoch from now()) * 1000)::bigint) where id = rid;
  if decision = 'aprobado' and r->>'type' = 'roster' then
    update charros set data = data || jsonb_build_object('teamId', r->>'teamId') where id = r->>'charroId';
  elsif decision = 'aprobado' and r->>'type' = 'afiliacion' then
    update teams set data = data || jsonb_build_object('lienzoId', r->>'lienzoId', 'lienzoStatus', 'aprobado') where id = r->>'teamId';
  end if;
end $$;

-- Recibir un caballo con el código que generó su dueño. Guarda al dueño anterior en el historial.
create or replace function public.claim_horse(code text) returns text
language plpgsql security definer set search_path = public as $$
declare r jsonb; h jsonb; rid text; uid text := auth.uid()::text; me jsonb := public.my_data();
  now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  if not public.is_approved() then raise exception 'Tu cuenta debe estar activa para recibir caballos'; end if;
  select id, data into rid, r from requests
    where data->>'type' = 'transfer' and data->>'status' = 'pendiente' and data->>'code' = upper(trim(code)) for update;
  if r is null then raise exception 'Código inválido o ya usado'; end if;
  select data into h from horses where id = r->>'horseId' for update;
  if h is null then raise exception 'El caballo ya no existe'; end if;
  if h->>'ownerId' = uid then raise exception 'Este caballo ya es tuyo'; end if;
  update horses set data = data || jsonb_build_object(
      'history', coalesce(data->'history', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
        'label', case when coalesce(h->>'ownerPublic', 'false') = 'true' and coalesce(h->>'ownerName', '') <> '' then h->>'ownerName' else 'Dueño anterior (privado)' end,
        'from', coalesce(h->'ownerSince', h->'createdAt'), 'to', now_ms)),
      'ownerId', uid, 'ownerName', '', 'ownerPublic', false, 'forSale', false, 'ownerSince', now_ms)
    where id = r->>'horseId';
  update requests set data = data || jsonb_build_object('status', 'aprobado', 'decidedBy', uid,
    'decidedByName', coalesce(me->>'name', ''), 'decidedAt', now_ms) where id = rid;
  return r->>'horseId';
end $$;

revoke all on function public.claim_horse(text) from public, anon;
grant execute on function public.claim_horse(text) to authenticated;

-- 3) TIEMPO REAL
do $$
declare t text;
begin
  foreach t in array array['horses','settings'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
