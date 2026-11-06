-- =====================================================================
-- CHARRERÍA PRO — Esquema para Supabase
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- 0) RESPALDO: si ya existían tablas con estos nombres pero de otra versión (sin la columna "data"),
--    se mueven al esquema "respaldo" con todos sus datos. No se borra nada.
create schema if not exists respaldo;
do $$
declare t text; n int;
begin
  foreach t in array array['profiles','lienzos','events','scores','sheets','audit','invites'] loop
    if exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = t)
       and not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t and column_name = 'data') then
      n := 1;
      while exists (select 1 from information_schema.tables where table_schema = 'respaldo' and table_name = t || '_v' || n) loop n := n + 1; end loop;
      execute format('alter table public.%I set schema respaldo', t);
      execute format('alter table respaldo.%I rename to %I', t, t || '_v' || n);
      raise notice 'Tabla anterior public.% movida a respaldo.%', t, t || '_v' || n;
    end if;
  end loop;
end $$;

-- 1) TABLAS (cada fila guarda el objeto completo en "data")
create table if not exists public.profiles (id text primary key, data jsonb not null, created_at timestamptz default now());
create table if not exists public.lienzos  (id text primary key, data jsonb not null, created_at timestamptz default now());
create table if not exists public.events   (id text primary key, data jsonb not null, created_at timestamptz default now());
create table if not exists public.scores   (id text primary key, data jsonb not null, created_at timestamptz default now());
create table if not exists public.audit    (id text primary key, data jsonb not null, created_at timestamptz default now());
create table if not exists public.invites  (id text primary key, data jsonb not null, created_at timestamptz default now());
create table if not exists public.sheets   (id text primary key, data jsonb not null, created_at timestamptz default now());

create index if not exists scores_event_idx on public.scores ((data->>'eventId'));
create index if not exists events_lienzo_idx on public.events ((data->>'lienzoId'));

-- 2) FUNCIONES DE PERMISOS
create or replace function public.my_data() returns jsonb
language sql stable security definer set search_path = public as $$
  select data from profiles where id = auth.uid()::text
$$;

create or replace function public.is_approved() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select data->>'status' = 'aprobado' from profiles where id = auth.uid()::text), false)
$$;

create or replace function public.is_super() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select data->>'role' = 'superadmin' and data->>'status' = 'aprobado'
                   from profiles where id = auth.uid()::text), false)
$$;

create or replace function public.owns_lienzo(lid text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_approved() and exists (
    select 1 from lienzos l
    where l.id = lid and l.data->>'ownerId' = auth.uid()::text and l.data->>'status' = 'aprobado')
$$;

create or replace function public.can_score(eid text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_super() or exists (
    select 1 from events e
    where e.id = eid and e.data->>'status' = 'en_vivo'
      and ( public.owns_lienzo(e.data->>'lienzoId')
            or ( public.is_approved()
                 and public.my_data()->>'role' = 'juez'
                 and public.my_data()->>'lienzoId' = e.data->>'lienzoId')))
$$;

create or replace function public.invite_ok(code text, r text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from invites i
                 where i.id = code and i.data->>'role' = r
                   and coalesce(i.data->>'used','false') <> 'true')
$$;

-- Hoja abierta (no entregada) de un equipo en una charreada
create or replace function public.sheet_open(eid text, tid text) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from sheets sh where sh.id = eid || '-' || tid and coalesce(sh.data->>'entregada','false') = 'true')
$$;

-- Puede firmar/entregar hojas: súper usuario, lienzo dueño o juez del lienzo, con la charreada en vivo o finalizada
create or replace function public.can_sheet(eid text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_super() or exists (
    select 1 from events e
    where e.id = eid and e.data->>'status' in ('en_vivo','finalizado')
      and ( public.owns_lienzo(e.data->>'lienzoId')
            or ( public.is_approved() and public.my_data()->>'role' = 'juez'
                 and public.my_data()->>'lienzoId' = e.data->>'lienzoId')))
$$;

-- Marca la invitación como usada cuando alguien se registra con ella
create or replace function public.use_invite() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.data->>'invite' is not null then
    update invites set data = data || jsonb_build_object('used', true, 'usedBy', new.id)
    where id = new.data->>'invite';
  end if;
  return new;
end $$;
drop trigger if exists trg_use_invite on public.profiles;
create trigger trg_use_invite after insert on public.profiles for each row execute function public.use_invite();

-- 3) SEGURIDAD POR FILA (RLS)
alter table public.profiles enable row level security;
alter table public.lienzos  enable row level security;
alter table public.events   enable row level security;
alter table public.scores   enable row level security;
alter table public.audit    enable row level security;
alter table public.invites  enable row level security;
alter table public.sheets   enable row level security;

-- Lectura pública: cualquiera ve lienzos, charreadas y calificaciones
drop policy if exists "lienzos lectura" on public.lienzos;
create policy "lienzos lectura" on public.lienzos for select using (true);
drop policy if exists "events lectura" on public.events;
create policy "events lectura" on public.events for select using (true);
drop policy if exists "scores lectura" on public.scores;
create policy "scores lectura" on public.scores for select using (true);

-- PERFILES: cada quien ve el suyo; el lienzo ve a sus jueces; el súper usuario ve todo
drop policy if exists "profiles lectura" on public.profiles;
create policy "profiles lectura" on public.profiles for select using (
  id = auth.uid()::text or public.is_super()
  or (profiles.data->>'lienzoId') in (select l.id from lienzos l where l.data->>'ownerId' = auth.uid()::text));

drop policy if exists "profiles alta" on public.profiles;
create policy "profiles alta" on public.profiles for insert with check (
  id = auth.uid()::text
  and profiles.data->>'role' in ('lienzo','juez')
  and ( profiles.data->>'status' = 'pendiente'
        or (profiles.data->>'status' = 'aprobado' and public.invite_ok(profiles.data->>'invite', profiles.data->>'role'))));

drop policy if exists "profiles admin" on public.profiles;
create policy "profiles admin" on public.profiles for update using (public.is_super()) with check (public.is_super());

drop policy if exists "profiles propio" on public.profiles;
create policy "profiles propio" on public.profiles for update using (id = auth.uid()::text) with check (
  id = auth.uid()::text
  and profiles.data->>'role'   = (select p.data->>'role'   from profiles p where p.id = profiles.id)
  and profiles.data->>'status' = (select p.data->>'status' from profiles p where p.id = profiles.id)
  and coalesce(profiles.data->>'lienzoId','') = coalesce((select p.data->>'lienzoId' from profiles p where p.id = profiles.id),''));

-- LIENZOS: el dueño lo crea (pendiente salvo invitación); solo el súper usuario cambia el estado
drop policy if exists "lienzos alta" on public.lienzos;
create policy "lienzos alta" on public.lienzos for insert with check (
  public.is_super()
  or (lienzos.data->>'ownerId' = auth.uid()::text
      and (lienzos.data->>'status' = 'pendiente' or public.is_approved())));

drop policy if exists "lienzos cambio" on public.lienzos;
create policy "lienzos cambio" on public.lienzos for update
  using (public.is_super() or lienzos.data->>'ownerId' = auth.uid()::text)
  with check (public.is_super() or (
    lienzos.data->>'ownerId' = auth.uid()::text
    and lienzos.data->>'status' = (select l.data->>'status' from lienzos l where l.id = lienzos.id)));

-- CHARREADAS: solo el lienzo verificado dueño (o súper usuario). "official" solo lo cambia el súper usuario
drop policy if exists "events alta" on public.events;
create policy "events alta" on public.events for insert with check (
  public.is_super()
  or (public.owns_lienzo(events.data->>'lienzoId') and coalesce(events.data->>'official','false') = 'false'));

drop policy if exists "events cambio" on public.events;
create policy "events cambio" on public.events for update
  using (public.is_super() or public.owns_lienzo(events.data->>'lienzoId'))
  with check (public.is_super() or (
    public.owns_lienzo(events.data->>'lienzoId')
    and coalesce(events.data->>'official','false') = coalesce((select e.data->>'official' from events e where e.id = events.id),'false')
    -- una charreada finalizada no se puede reabrir (solo el súper usuario); sí se le puede subir el video
    and ( (select e.data->>'status' from events e where e.id = events.id) is distinct from 'finalizado'
          or events.data->>'status' = 'finalizado')));

-- JUECES: durante la charreada en vivo pueden AGREGAR charros (cambios de último momento).
-- No pueden cambiar nada más del evento ni quitar o editar charros existentes.
drop policy if exists "events juez agrega charro" on public.events;
create policy "events juez agrega charro" on public.events for update
  using (public.can_score(events.id))
  with check (
    public.can_score(events.id)
    and (events.data - 'charros') = (select e.data - 'charros' from events e where e.id = events.id)
    and events.data->'charros' @> (select e.data->'charros' from events e where e.id = events.id)
    and not exists (   -- cada charro nuevo queda a nombre del juez que lo agregó
      select 1 from jsonb_array_elements(events.data->'charros') c
      where not ((select e.data->'charros' from events e where e.id = events.id) @> jsonb_build_array(c))
        and c->>'addedBy' is distinct from auth.uid()::text));

-- CALIFICACIONES (una fila por equipo y faena): solo jueces autorizados del lienzo, con la charreada en vivo
-- y mientras la hoja del equipo no haya sido entregada (el súper usuario siempre puede corregir)
drop policy if exists "scores alta" on public.scores;
create policy "scores alta" on public.scores for insert with check (
  public.can_score(scores.data->>'eventId') and scores.data->>'judgeId' = auth.uid()::text
  and (public.is_super() or public.sheet_open(scores.data->>'eventId', scores.data->>'teamId')));

drop policy if exists "scores cambio" on public.scores;
create policy "scores cambio" on public.scores for update
  using (public.can_score(scores.data->>'eventId'))
  with check (public.can_score(scores.data->>'eventId') and scores.data->>'judgeId' = auth.uid()::text
    and (public.is_super() or public.sheet_open(scores.data->>'eventId', scores.data->>'teamId')));

-- HOJAS DE CALIFICACIÓN: lectura pública; solo jueces/lienzo las entregan; una vez entregada solo se puede
-- agregar firma de otro juez, y solo el súper usuario la reabre
drop policy if exists "sheets lectura" on public.sheets;
create policy "sheets lectura" on public.sheets for select using (true);
drop policy if exists "sheets alta" on public.sheets;
create policy "sheets alta" on public.sheets for insert with check (public.can_sheet(sheets.data->>'eventId'));
drop policy if exists "sheets cambio" on public.sheets;
create policy "sheets cambio" on public.sheets for update
  using (public.can_sheet(sheets.data->>'eventId'))
  with check (public.is_super() or (
    public.can_sheet(sheets.data->>'eventId')
    and ( coalesce((select sh.data->>'entregada' from sheets sh where sh.id = sheets.id),'false') <> 'true'
          or ( sheets.data->>'entregada' = 'true'
               and sheets.data->'totals' = (select sh.data->'totals' from sheets sh where sh.id = sheets.id)))));

-- BITÁCORA: todos escriben a su nombre, solo el súper usuario lee. Nadie edita ni borra.
drop policy if exists "audit alta" on public.audit;
create policy "audit alta" on public.audit for insert with check (auth.uid() is not null and audit.data->>'actorId' = auth.uid()::text);
drop policy if exists "audit lectura" on public.audit;
create policy "audit lectura" on public.audit for select using (public.is_super());

-- INVITACIONES: solo el súper usuario
drop policy if exists "invites admin" on public.invites;
create policy "invites admin" on public.invites for all using (public.is_super()) with check (public.is_super());

-- 4) TIEMPO REAL
do $$
declare t text;
begin
  foreach t in array array['profiles','lienzos','events','scores','audit','invites','sheets'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- 5) VIDEOS (Storage)
insert into storage.buckets (id, name, public) values ('videos', 'videos', true) on conflict (id) do nothing;
drop policy if exists "videos lectura" on storage.objects;
create policy "videos lectura" on storage.objects for select using (bucket_id = 'videos');
drop policy if exists "videos subida" on storage.objects;
create policy "videos subida" on storage.objects for insert to authenticated with check (bucket_id = 'videos' and public.is_approved());

-- =====================================================================
-- 5b) PERFILES DE CHARROS, EQUIPOS Y DUEÑOS DE CABALLOS
-- =====================================================================

-- 1) TABLAS
create table if not exists public.charros  (id text primary key, data jsonb not null, created_at timestamptz default now());
create table if not exists public.teams    (id text primary key, data jsonb not null, created_at timestamptz default now());
create table if not exists public.requests (id text primary key, data jsonb not null, created_at timestamptz default now());
create index if not exists charros_team_idx on public.charros ((data->>'teamId'));
create index if not exists requests_team_idx on public.requests ((data->>'teamId'));

alter table public.charros  enable row level security;
alter table public.teams    enable row level security;
alter table public.requests enable row level security;

-- 2) PERMISOS
-- Puede aprobar el roster de un equipo: súper usuario, su capitán, o el lienzo y los jueces del lienzo al que está afiliado
create or replace function public.can_decide_team(tid text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_super() or exists (
    select 1 from teams t where t.id = tid and (
      t.data->>'captainId' = auth.uid()::text
      or ( t.data->>'lienzoStatus' = 'aprobado'
           and ( public.owns_lienzo(t.data->>'lienzoId')
                 or ( public.is_approved() and public.my_data()->>'role' = 'juez'
                      and public.my_data()->>'lienzoId' = t.data->>'lienzoId')))))
$$;

-- Cuentas nuevas: charros, capitanes de equipo y dueños de caballos quedan activos al registrarse;
-- lo "oficial" lo da la aprobación del roster o de la afiliación
drop policy if exists "profiles alta" on public.profiles;
create policy "profiles alta" on public.profiles for insert with check (
  id = auth.uid()::text
  and profiles.data->>'role' in ('lienzo','juez','charro','equipo','dueno')
  and ( profiles.data->>'status' = 'pendiente'
        or (profiles.data->>'status' = 'aprobado' and profiles.data->>'role' in ('charro','equipo','dueno'))
        or (profiles.data->>'status' = 'aprobado' and public.invite_ok(profiles.data->>'invite', profiles.data->>'role'))));

-- Solo lienzos, jueces y súper usuario suben videos
drop policy if exists "videos subida" on storage.objects;
create policy "videos subida" on storage.objects for insert to authenticated with check (
  bucket_id = 'videos' and public.is_approved() and public.my_data()->>'role' in ('lienzo','juez','superadmin'));

-- CHARROS: lectura pública; cada charro edita su perfil, pero su equipo solo cambia con una solicitud aprobada
drop policy if exists "charros lectura" on public.charros;
create policy "charros lectura" on public.charros for select using (true);
drop policy if exists "charros alta" on public.charros;
create policy "charros alta" on public.charros for insert with check (
  public.is_super() or (charros.data->>'userId' = auth.uid()::text and coalesce(charros.data->>'teamId','') = ''));
drop policy if exists "charros cambio" on public.charros;
create policy "charros cambio" on public.charros for update
  using (public.is_super() or charros.data->>'userId' = auth.uid()::text)
  with check (public.is_super() or (
    charros.data->>'userId' = auth.uid()::text
    and coalesce(charros.data->>'teamId','') = coalesce((select c.data->>'teamId' from charros c where c.id = charros.id),'')));

-- EQUIPOS: lectura pública; el capitán edita su equipo, pero la afiliación al lienzo solo cambia con una solicitud aprobada
drop policy if exists "teams lectura" on public.teams;
create policy "teams lectura" on public.teams for select using (true);
drop policy if exists "teams alta" on public.teams;
create policy "teams alta" on public.teams for insert with check (
  public.is_super() or (teams.data->>'captainId' = auth.uid()::text
    and coalesce(teams.data->>'lienzoId','') = '' and coalesce(teams.data->>'lienzoStatus','') = ''));
drop policy if exists "teams cambio" on public.teams;
create policy "teams cambio" on public.teams for update
  using (public.is_super() or teams.data->>'captainId' = auth.uid()::text)
  with check (public.is_super() or (
    teams.data->>'captainId' = auth.uid()::text
    and coalesce(teams.data->>'lienzoId','') = coalesce((select t.data->>'lienzoId' from teams t where t.id = teams.id),'')
    and coalesce(teams.data->>'lienzoStatus','') = coalesce((select t.data->>'lienzoStatus' from teams t where t.id = teams.id),'')));

-- SOLICITUDES: las ven los usuarios con sesión; se crean pendientes y solo se resuelven con decide_request()
drop policy if exists "requests lectura" on public.requests;
create policy "requests lectura" on public.requests for select using (auth.uid() is not null);
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
                          and r.data->>'teamId' = requests.data->>'teamId') )));

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
    elsif not public.can_decide_team(r->>'teamId') then raise exception 'No tienes permiso para esta acción'; end if;
  else raise exception 'Decisión inválida'; end if;

  update requests set data = data || jsonb_build_object('status', decision, 'decidedBy', uid,
    'decidedByName', coalesce(me->>'name', ''), 'decidedAt', (extract(epoch from now()) * 1000)::bigint) where id = rid;
  if decision = 'aprobado' and r->>'type' = 'roster' then
    update charros set data = data || jsonb_build_object('teamId', r->>'teamId') where id = r->>'charroId';
  elsif decision = 'aprobado' and r->>'type' = 'afiliacion' then
    update teams set data = data || jsonb_build_object('lienzoId', r->>'lienzoId', 'lienzoStatus', 'aprobado') where id = r->>'teamId';
  end if;
end $$;

-- Sacar a un charro de su equipo: el propio charro, quien puede aprobar el roster de ese equipo, o el súper usuario
create or replace function public.roster_remove(cid text) returns void
language plpgsql security definer set search_path = public as $$
declare c jsonb;
begin
  select data into c from charros where id = cid for update;
  if c is null then raise exception 'Charro no encontrado'; end if;
  if not (c->>'userId' = auth.uid()::text or public.can_decide_team(c->>'teamId')) then
    raise exception 'No tienes permiso para esta acción'; end if;
  update charros set data = data || jsonb_build_object('teamId', null) where id = cid;
end $$;

revoke all on function public.decide_request(text, text) from public, anon;
revoke all on function public.roster_remove(text) from public, anon;
grant execute on function public.decide_request(text, text) to authenticated;
grant execute on function public.roster_remove(text) to authenticated;

-- 3) TIEMPO REAL
do $$
declare t text;
begin
  foreach t in array array['charros','teams','requests'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- =====================================================================
-- 5c) CABALLOS, CAMBIO DE DUEÑO, VALUACIÓN Y VITRINA
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

-- =====================================================================
-- 5d) VALUACIÓN REALISTA, DEMANDA Y PRECIO FIJADO
-- =====================================================================
-- 1) DEMANDA PÚBLICA POR CABALLO (cuántos compradores verificados se interesaron en los últimos 180 días).
-- Los contactos siguen siendo privados; aquí solo se guarda el número.
create table if not exists public.horse_demand (id text primary key, data jsonb not null, created_at timestamptz default now());
alter table public.horse_demand enable row level security;
drop policy if exists "horse_demand lectura" on public.horse_demand;
create policy "horse_demand lectura" on public.horse_demand for select using (true);
-- Sin políticas de escritura: solo la actualiza la función recompute_horse_demand().

-- Comprador verificado: lienzo autorizado, o charro / capitán de equipo que el súper usuario verificó
create or replace function public.is_verified_buyer(pdata jsonb) returns boolean
language sql immutable as $$
  select coalesce(pdata->>'status', '') = 'aprobado'
     and ( pdata->>'role' = 'lienzo'
           or (pdata->>'role' in ('charro','equipo') and coalesce(pdata->>'verified', 'false') = 'true'))
$$;

create or replace function public.recompute_horse_demand(hid text) returns void
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if hid is null then return; end if;
  select count(distinct r.data->>'createdBy') into n
    from requests r join profiles p on p.id = r.data->>'createdBy'
    where r.data->>'type' = 'interes' and r.data->>'horseId' = hid
      and r.data->>'status' in ('pendiente','aprobado')
      and coalesce((r.data->>'createdAt')::bigint, 0) > (extract(epoch from now() - interval '180 days') * 1000)::bigint
      and public.is_verified_buyer(p.data);
  insert into horse_demand (id, data) values (hid, jsonb_build_object('id', hid, 'demand', n, 'updatedAt', (extract(epoch from now()) * 1000)::bigint))
  on conflict (id) do update set data = excluded.data;
end $$;
revoke all on function public.recompute_horse_demand(text) from public, anon, authenticated;

create or replace function public.trg_requests_demand() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.data->>'type' = 'interes' then perform public.recompute_horse_demand(new.data->>'horseId'); end if;
  return new;
end $$;
drop trigger if exists trg_requests_demand on public.requests;
create trigger trg_requests_demand after insert or update on public.requests for each row execute function public.trg_requests_demand();

-- Si el súper usuario verifica o quita la verificación de un comprador, se recalcula la demanda de sus caballos
create or replace function public.trg_profiles_demand() returns trigger
language plpgsql security definer set search_path = public as $$
declare hid text;
begin
  if coalesce(old.data->>'verified','') is distinct from coalesce(new.data->>'verified','')
     or coalesce(old.data->>'status','') is distinct from coalesce(new.data->>'status','') then
    for hid in select distinct r.data->>'horseId' from requests r where r.data->>'type' = 'interes' and r.data->>'createdBy' = new.id loop
      perform public.recompute_horse_demand(hid);
    end loop;
  end if;
  return new;
end $$;
drop trigger if exists trg_profiles_demand on public.profiles;
create trigger trg_profiles_demand after update on public.profiles for each row execute function public.trg_profiles_demand();

-- 2) Nadie se puede auto-verificar: el usuario no cambia su propio "verified"
drop policy if exists "profiles propio" on public.profiles;
create policy "profiles propio" on public.profiles for update using (id = auth.uid()::text) with check (
  id = auth.uid()::text
  and profiles.data->>'role'   = (select p.data->>'role'   from profiles p where p.id = profiles.id)
  and profiles.data->>'status' = (select p.data->>'status' from profiles p where p.id = profiles.id)
  and coalesce(profiles.data->>'lienzoId','') = coalesce((select p.data->>'lienzoId' from profiles p where p.id = profiles.id),'')
  and coalesce(profiles.data->>'verified','false') = coalesce((select p.data->>'verified' from profiles p where p.id = profiles.id),'false'));

-- 3) El precio fijado (priceOverride) solo lo pone o quita el súper usuario
drop policy if exists "horses cambio" on public.horses;
create policy "horses cambio" on public.horses for update
  using (public.is_super() or horses.data->>'ownerId' = auth.uid()::text)
  with check (public.is_super() or (
    horses.data->>'ownerId' = auth.uid()::text
    and coalesce(horses.data->'history', '[]'::jsonb) = coalesce((select h.data->'history' from horses h where h.id = horses.id), '[]'::jsonb)
    and coalesce(horses.data->'priceOverride', 'null'::jsonb) = coalesce((select h.data->'priceOverride' from horses h where h.id = horses.id), 'null'::jsonb)));
drop policy if exists "horses alta" on public.horses;
create policy "horses alta" on public.horses for insert with check (
  public.is_approved() and horses.data->>'ownerId' = auth.uid()::text
  and jsonb_array_length(coalesce(horses.data->'history', '[]'::jsonb)) = 0
  and coalesce(horses.data->'priceOverride', 'null'::jsonb) = 'null'::jsonb);

-- Recalcula la demanda de los caballos que ya tienen interesados
do $$ declare hid text; begin
  for hid in select distinct data->>'horseId' from requests where data->>'type' = 'interes' loop perform public.recompute_horse_demand(hid); end loop;
end $$;

-- 4) TIEMPO REAL
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'horse_demand') then
    alter publication supabase_realtime add table public.horse_demand;
  end if;
end $$;

-- =====================================================================
-- 5e) VERIFICACIÓN PENDIENTE / OFICIAL
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

-- =====================================================================
-- 5f) GANADERÍAS, GANADO Y RENTA
-- =====================================================================
-- 1) TABLAS
create table if not exists public.ranches (id text primary key, data jsonb not null, created_at timestamptz default now());
create table if not exists public.stock   (id text primary key, data jsonb not null, created_at timestamptz default now());
create index if not exists stock_ranch_idx on public.stock ((data->>'ranchId'));
alter table public.ranches enable row level security;
alter table public.stock   enable row level security;

-- 2) Cuenta de ganadero: queda activa al registrarse; lo "oficial" lo da la verificación
drop policy if exists "profiles alta" on public.profiles;
create policy "profiles alta" on public.profiles for insert with check (
  id = auth.uid()::text
  and profiles.data->>'role' in ('lienzo','juez','charro','equipo','dueno','ganadero')
  and coalesce(profiles.data->>'verified','false') = 'false'
  and ( profiles.data->>'status' = 'pendiente'
        or (profiles.data->>'status' = 'aprobado' and profiles.data->>'role' in ('charro','equipo','dueno','ganadero'))
        or (profiles.data->>'status' = 'aprobado' and public.invite_ok(profiles.data->>'invite', profiles.data->>'role'))));

-- 3) GANADERÍAS: lectura pública (el ganadero publica su contacto para renta); el dueño las edita sin tocar la verificación
drop policy if exists "ranches lectura" on public.ranches;
create policy "ranches lectura" on public.ranches for select using (true);
drop policy if exists "ranches alta" on public.ranches;
create policy "ranches alta" on public.ranches for insert with check (
  public.is_approved() and ranches.data->>'ownerId' = auth.uid()::text
  and ranches.data->'verif' is null and ranches.data->'verifKey' is null);
drop policy if exists "ranches cambio" on public.ranches;
create policy "ranches cambio" on public.ranches for update
  using (public.is_super() or ranches.data->>'ownerId' = auth.uid()::text)
  with check (public.is_super() or (ranches.data->>'ownerId' = auth.uid()::text
    and public.verif_of(ranches.data) = public.verif_of((select r.data from ranches r where r.id = ranches.id))));
drop policy if exists "ranches baja" on public.ranches;
create policy "ranches baja" on public.ranches for delete using (public.is_super() or ranches.data->>'ownerId' = auth.uid()::text);

-- GANADO: toros y yeguas de una ganadería del mismo dueño
drop policy if exists "stock lectura" on public.stock;
create policy "stock lectura" on public.stock for select using (true);
drop policy if exists "stock alta" on public.stock;
create policy "stock alta" on public.stock for insert with check (
  stock.data->>'ownerId' = auth.uid()::text
  and exists (select 1 from ranches r where r.id = stock.data->>'ranchId' and r.data->>'ownerId' = auth.uid()::text)
  and stock.data->'verif' is null and stock.data->'verifKey' is null);
drop policy if exists "stock cambio" on public.stock;
create policy "stock cambio" on public.stock for update
  using (public.is_super() or stock.data->>'ownerId' = auth.uid()::text)
  with check (public.is_super() or (stock.data->>'ownerId' = auth.uid()::text
    and exists (select 1 from ranches r where r.id = stock.data->>'ranchId' and r.data->>'ownerId' = auth.uid()::text)
    and public.verif_of(stock.data) = public.verif_of((select s.data from stock s where s.id = stock.id))));
drop policy if exists "stock baja" on public.stock;
create policy "stock baja" on public.stock for delete using (public.is_super() or stock.data->>'ownerId' = auth.uid()::text);

-- 4) VERIFICACIÓN: ganaderías y ganado (incluye el precio de renta en la huella)
create or replace function public.verif_key(kind text, d jsonb) returns text
language sql immutable as $$
  select case kind
    when 'charro' then public.vk(d, 'name', 'category')
    when 'team'   then public.vk(d, 'name', 'state')
    when 'horse'  then public.vk(d, 'name', 'registry', 'breed', 'training', 'birthYear', 'discipline', 'sex')
    when 'ranch'  then public.vk(d, 'name', 'state', 'whatsapp', 'phone')
    when 'stock'  then public.vk(d, 'name', 'kind', 'mode', 'count', 'rentPrice', 'rentUnit')
  end
$$;

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
  elsif kind = 'stock' then
    select exists (select 1 from events e, jsonb_array_elements(coalesce(e.data->'stock', '[]'::jsonb)) x
                   where e.data->>'lienzoId' = lid and x->>'stockId' = rid) into ok;
  elsif kind = 'ranch' then
    select exists (select 1 from events e, jsonb_array_elements(coalesce(e.data->'stock', '[]'::jsonb)) x
                   join stock s on s.id = x->>'stockId'
                   where e.data->>'lienzoId' = lid and s.data->>'ranchId' = rid) into ok;
  end if;
  return ok;
end $$;

create or replace function public.set_verified(kind text, rid text, decision text, note text default '') returns void
language plpgsql security definer set search_path = public as $$
declare tbl text; d jsonb; me jsonb := public.my_data(); now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  tbl := case kind when 'charro' then 'charros' when 'team' then 'teams' when 'horse' then 'horses' when 'ranch' then 'ranches' when 'stock' then 'stock' end;
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

-- 5) TIEMPO REAL
do $$ declare t text; begin
  foreach t in array array['ranches','stock'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- =====================================================================
-- 5g) CALIFICACIÓN DEL GANADO
-- =====================================================================
create table if not exists public.stock_ratings (id text primary key, data jsonb not null, created_at timestamptz default now());
create index if not exists stock_ratings_stock_idx on public.stock_ratings ((data->>'stockId'));
alter table public.stock_ratings enable row level security;

-- Lectura pública: el historial de calidad del ganado es público
drop policy if exists "stock_ratings lectura" on public.stock_ratings;
create policy "stock_ratings lectura" on public.stock_ratings for select using (true);

-- Califica: súper usuario, el lienzo dueño o un juez del lienzo, con la charreada en vivo o finalizada,
-- solo ganado que el lienzo registró en esa charreada, una calificación por persona, a su nombre, de 1 a 5
create or replace function public.rating_ok(d jsonb, rid text) returns boolean
language sql stable security definer set search_path = public as $$
  select d->>'raterId' = auth.uid()::text
    and rid = (d->>'eventId') || '-' || (d->>'stockId') || '-' || auth.uid()::text
    and public.can_sheet(d->>'eventId')
    and exists (select 1 from events e, jsonb_array_elements(coalesce(e.data->'stock', '[]'::jsonb)) x
                where e.id = d->>'eventId' and x->>'stockId' = d->>'stockId')
    and (d->'scores'->>'des')::int between 1 and 5
    and (d->'scores'->>'con')::int between 1 and 5
    and (d->'scores'->>'seg')::int between 1 and 5
$$;
drop policy if exists "stock_ratings alta" on public.stock_ratings;
create policy "stock_ratings alta" on public.stock_ratings for insert with check (public.rating_ok(stock_ratings.data, stock_ratings.id));
drop policy if exists "stock_ratings cambio" on public.stock_ratings;
create policy "stock_ratings cambio" on public.stock_ratings for update
  using (stock_ratings.data->>'raterId' = auth.uid()::text)
  with check (public.rating_ok(stock_ratings.data, stock_ratings.id));

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'stock_ratings') then
    alter publication supabase_realtime add table public.stock_ratings;
  end if;
end $$;

-- =====================================================================
-- 5h) AJUSTES ADMINISTRATIVOS DEL SÚPER USUARIO
-- =====================================================================
-- Solo guarda números y la marca de ajuste. El motivo y quién lo pidió van a la bitácora (solo la lee el súper usuario).
create table if not exists public.adjust (id text primary key, data jsonb not null, created_at timestamptz default now());
alter table public.adjust enable row level security;
drop policy if exists "adjust lectura" on public.adjust;
create policy "adjust lectura" on public.adjust for select using (true);
drop policy if exists "adjust admin" on public.adjust;
create policy "adjust admin" on public.adjust for all using (public.is_super()) with check (public.is_super());

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'adjust') then
    alter publication supabase_realtime add table public.adjust;
  end if;
end $$;

-- =====================================================================
-- 5i) PLAN PRO, KIT DE MICROCHIP Y CARNET DIGITAL
-- =====================================================================
-- 1) PRECIOS (los cambia el súper usuario desde la app)
insert into public.settings (id, data) values ('precios', '{"id":"precios","pro":99,"kit":699}'::jsonb)
on conflict (id) do nothing;

-- 2) PLAN PRO: nadie se lo pone editando su perfil; solo con activate_pro() o el súper usuario
drop policy if exists "profiles propio" on public.profiles;
create policy "profiles propio" on public.profiles for update using (id = auth.uid()::text) with check (
  id = auth.uid()::text
  and profiles.data->>'role'   = (select p.data->>'role'   from profiles p where p.id = profiles.id)
  and profiles.data->>'status' = (select p.data->>'status' from profiles p where p.id = profiles.id)
  and coalesce(profiles.data->>'lienzoId','') = coalesce((select p.data->>'lienzoId' from profiles p where p.id = profiles.id),'')
  and coalesce(profiles.data->>'verified','false') = coalesce((select p.data->>'verified' from profiles p where p.id = profiles.id),'false')
  and coalesce(profiles.data->>'subscriptionStatus','free') = coalesce((select p.data->>'subscriptionStatus' from profiles p where p.id = profiles.id),'free')
  and coalesce(profiles.data->>'proUntil','') = coalesce((select p.data->>'proUntil' from profiles p where p.id = profiles.id),''));

drop policy if exists "profiles alta" on public.profiles;
create policy "profiles alta" on public.profiles for insert with check (
  id = auth.uid()::text
  and profiles.data->>'role' in ('lienzo','juez','charro','equipo','dueno','ganadero')
  and coalesce(profiles.data->>'verified','false') = 'false'
  and coalesce(profiles.data->>'subscriptionStatus','free') = 'free'
  and ( profiles.data->>'status' = 'pendiente'
        or (profiles.data->>'status' = 'aprobado' and profiles.data->>'role' in ('charro','equipo','dueno','ganadero'))
        or (profiles.data->>'status' = 'aprobado' and public.invite_ok(profiles.data->>'invite', profiles.data->>'role'))));

-- Pago SIMULADO: activa Pro 30 días. Para cobrar de verdad, reemplaza esta función por la confirmación del procesador de pagos.
create or replace function public.activate_pro() returns bigint
language plpgsql security definer set search_path = public as $$
declare until_ms bigint; cur bigint;
begin
  if auth.uid() is null then raise exception 'Inicia sesión para activar Pro'; end if;
  select coalesce((data->>'proUntil')::bigint, 0) into cur from profiles where id = auth.uid()::text;
  until_ms := greatest(cur, (extract(epoch from now()) * 1000)::bigint) + 30::bigint * 86400000;
  update profiles set data = data || jsonb_build_object('subscriptionStatus', 'pro', 'proUntil', until_ms, 'proRef', 'SIMULADO') where id = auth.uid()::text;
  return until_ms;
end $$;
revoke all on function public.activate_pro() from public, anon;
grant execute on function public.activate_pro() to authenticated;

-- 3) PEDIDOS DE KIT: el dueño los crea; los datos de envío solo los ven él y el súper usuario (política "requests lectura")
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
                      and h.data->>'ownerId' is distinct from auth.uid()::text) )
     or ( requests.data->>'type' = 'chip_order'
          and ( (requests.data->>'targetKind' = 'horse' and exists (select 1 from horses h where h.id = requests.data->>'targetId' and h.data->>'ownerId' = auth.uid()::text))
             or (requests.data->>'targetKind' = 'stock' and exists (select 1 from stock s where s.id = requests.data->>'targetId' and s.data->>'ownerId' = auth.uid()::text)) )
          and coalesce(requests.data->>'kitUid', '') = '' ) ));

-- El súper usuario actualiza pedidos (enviado, UID del chip, guía de paquetería, entregado)
drop policy if exists "requests admin" on public.requests;
create policy "requests admin" on public.requests for update using (public.is_super()) with check (public.is_super());

-- 4) MICROCHIP Y CARNET: los campos del chip solo cambian con register_chip() / validate_chip()
create or replace function public.chip_of(d jsonb) returns jsonb
language sql immutable as $$
  select jsonb_build_object('chipUid', d->'chipUid', 'chipStatus', d->'chipStatus', 'chipAt', d->'chipAt', 'chipValidatedBy', d->'chipValidatedBy')
$$;

drop policy if exists "horses alta" on public.horses;
create policy "horses alta" on public.horses for insert with check (
  public.is_approved() and horses.data->>'ownerId' = auth.uid()::text
  and jsonb_array_length(coalesce(horses.data->'history', '[]'::jsonb)) = 0
  and coalesce(horses.data->'priceOverride', 'null'::jsonb) = 'null'::jsonb
  and horses.data->'verif' is null and horses.data->'verifKey' is null and horses.data->'chipUid' is null);
drop policy if exists "horses cambio" on public.horses;
create policy "horses cambio" on public.horses for update
  using (public.is_super() or horses.data->>'ownerId' = auth.uid()::text)
  with check (public.is_super() or (
    horses.data->>'ownerId' = auth.uid()::text
    and coalesce(horses.data->'history', '[]'::jsonb) = coalesce((select h.data->'history' from horses h where h.id = horses.id), '[]'::jsonb)
    and coalesce(horses.data->'priceOverride', 'null'::jsonb) = coalesce((select h.data->'priceOverride' from horses h where h.id = horses.id), 'null'::jsonb)
    and public.verif_of(horses.data) = public.verif_of((select h.data from horses h where h.id = horses.id))
    and public.chip_of(horses.data) = public.chip_of((select h.data from horses h where h.id = horses.id))));

drop policy if exists "stock alta" on public.stock;
create policy "stock alta" on public.stock for insert with check (
  stock.data->>'ownerId' = auth.uid()::text
  and exists (select 1 from ranches r where r.id = stock.data->>'ranchId' and r.data->>'ownerId' = auth.uid()::text)
  and stock.data->'verif' is null and stock.data->'verifKey' is null and stock.data->'chipUid' is null);
drop policy if exists "stock cambio" on public.stock;
create policy "stock cambio" on public.stock for update
  using (public.is_super() or stock.data->>'ownerId' = auth.uid()::text)
  with check (public.is_super() or (stock.data->>'ownerId' = auth.uid()::text
    and exists (select 1 from ranches r where r.id = stock.data->>'ranchId' and r.data->>'ownerId' = auth.uid()::text)
    and public.verif_of(stock.data) = public.verif_of((select s.data from stock s where s.id = stock.id))
    and public.chip_of(stock.data) = public.chip_of((select s.data from stock s where s.id = stock.id))));

-- Registrar el UID del chip: el dueño del ejemplar. Si el UID coincide con el chip de un kit que se le envió, queda validado;
-- si no, queda pendiente de que el súper usuario lo valide. Un UID no se puede repetir en dos ejemplares.
create or replace function public.register_chip(kind text, rid text, uid text) returns text
language plpgsql security definer set search_path = public as $$
declare tbl text; d jsonb; u text := upper(regexp_replace(coalesce(uid, ''), '[^0-9A-Fa-f]', '', 'g')); st text;
  now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  tbl := case kind when 'horse' then 'horses' when 'stock' then 'stock' end;
  if tbl is null then raise exception 'Tipo inválido'; end if;
  if length(u) < 8 or length(u) > 32 then raise exception 'El UID debe tener entre 8 y 32 caracteres hexadecimales'; end if;
  execute format('select data from %I where id = $1 for update', tbl) into d using rid;
  if d is null then raise exception 'Ejemplar no encontrado'; end if;
  if d->>'ownerId' is distinct from auth.uid()::text then raise exception 'Solo el dueño registra el chip'; end if;
  if coalesce(d->>'chipStatus', '') = 'validado' then raise exception 'Este ejemplar ya tiene un chip validado'; end if;
  if exists (select 1 from horses where data->>'chipUid' = u and id <> rid) or exists (select 1 from stock where data->>'chipUid' = u and id <> rid) then
    raise exception 'Ese chip ya está registrado en otro ejemplar'; end if;
  st := case when exists (select 1 from requests r where r.data->>'type' = 'chip_order' and r.data->>'createdBy' = auth.uid()::text
                          and upper(regexp_replace(coalesce(r.data->>'kitUid', ''), '[^0-9A-Fa-f]', '', 'g')) = u
                          and r.data->>'status' in ('enviado', 'entregado')) then 'validado' else 'pendiente' end;
  execute format('update %I set data = data || $1 where id = $2', tbl) using jsonb_build_object(
    'chipUid', u, 'chipStatus', st, 'chipAt', now_ms, 'chipValidatedBy', case when st = 'validado' then 'kit' else null end), rid;
  return st;
end $$;
revoke all on function public.register_chip(text, text, text) from public, anon;
grant execute on function public.register_chip(text, text, text) to authenticated;

create or replace function public.validate_chip(kind text, rid text, ok boolean) returns void
language plpgsql security definer set search_path = public as $$
declare tbl text; me jsonb := public.my_data();
begin
  if not public.is_super() then raise exception 'Solo el súper usuario valida chips'; end if;
  tbl := case kind when 'horse' then 'horses' when 'stock' then 'stock' end;
  if tbl is null then raise exception 'Tipo inválido'; end if;
  execute format('update %I set data = data || $1 where id = $2', tbl) using jsonb_build_object(
    'chipStatus', case when ok then 'validado' else 'rechazado' end, 'chipValidatedBy', coalesce(me->>'name', 'Súper usuario'),
    'chipAt', (extract(epoch from now()) * 1000)::bigint), rid;
end $$;
revoke all on function public.validate_chip(text, text, boolean) from public, anon;
grant execute on function public.validate_chip(text, text, boolean) to authenticated;

-- =====================================================================
-- CHARRERÍA PRO — Actualización: base limpia de CharreríaTCG
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run. Se puede correr varias veces.
-- =====================================================================

-- Catálogo público de cartas. Nadie lo escribe a mano: lo mantienen los disparadores de abajo.
-- Una carta existe si su dueño tiene Pro vigente y autorización, y si el registro está verificado.
create table if not exists public.tcg_cards (id text primary key, data jsonb not null, created_at timestamptz default now());
alter table public.tcg_cards enable row level security;
drop policy if exists "tcg_cards lectura" on public.tcg_cards;
create policy "tcg_cards lectura" on public.tcg_cards for select using (true);
grant select on public.tcg_cards to anon, authenticated;   -- solo lectura: Supabase ya no da acceso automático a las tablas nuevas

-- Debe coincidir con tcgSyncLocal() de la app
create or replace function public.tcg_sync(kind text, rid text) returns void
language plpgsql security definer set search_path = public as $$
declare tbl text; d jsonb; p jsonb; owner_id text; now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  tbl := case kind when 'charro' then 'charros' when 'horse' then 'horses' when 'stock' then 'stock' end;
  if tbl is null then return; end if;
  execute format('select data from %I where id = $1', tbl) into d using rid;
  owner_id := case when kind = 'charro' then d->>'userId' else d->>'ownerId' end;
  if owner_id is not null then select data into p from profiles where id = owner_id; end if;
  if d is not null and p is not null and p->'tcgConsent' is not null and jsonb_typeof(p->'tcgConsent') = 'object'
     and p->>'subscriptionStatus' = 'pro' and coalesce((p->>'proUntil')::bigint, 0) > now_ms
     and d->>'verif' = 'oficial' and d->>'verifKey' = public.verif_key(kind, d)
     and (kind <> 'stock' or d->>'mode' = 'unidad') then
    insert into tcg_cards (id, data) values (kind || '-' || rid, jsonb_build_object('id', kind || '-' || rid, 'kind', kind, 'refId', rid,
      'name', d->>'name', 'ownerId', owner_id, 'activeUntil', (p->>'proUntil')::bigint, 'updatedAt', now_ms))
    on conflict (id) do update set data = excluded.data;
  else
    delete from tcg_cards where id = kind || '-' || rid;
  end if;
end $$;
revoke all on function public.tcg_sync(text, text) from public, anon, authenticated;

create or replace function public.trg_tcg_source() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.tcg_sync(tg_argv[0], coalesce(new.id, old.id));
  return null;
end $$;

create or replace function public.trg_tcg_profile() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select 'charro' k, id from charros where data->>'userId' = new.id
     union all select 'horse', id from horses where data->>'ownerId' = new.id
     union all select 'stock', id from stock where data->>'ownerId' = new.id loop
    perform public.tcg_sync(r.k, r.id);
  end loop;
  return null;
end $$;

drop trigger if exists trg_tcg_charros on public.charros;
create trigger trg_tcg_charros after insert or update or delete on public.charros for each row execute function public.trg_tcg_source('charro');
drop trigger if exists trg_tcg_horses on public.horses;
create trigger trg_tcg_horses after insert or update or delete on public.horses for each row execute function public.trg_tcg_source('horse');
drop trigger if exists trg_tcg_stock on public.stock;
create trigger trg_tcg_stock after insert or update or delete on public.stock for each row execute function public.trg_tcg_source('stock');
drop trigger if exists trg_tcg_profiles on public.profiles;
create trigger trg_tcg_profiles after insert or update on public.profiles for each row execute function public.trg_tcg_profile();

-- Avisa a la app en tiempo real
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'tcg_cards') then
    alter publication supabase_realtime add table public.tcg_cards;
  end if;
end $$;

-- Llena el catálogo con lo que ya existe
do $$ declare r record; begin
  for r in select 'charro' k, id from charros union all select 'horse', id from horses union all select 'stock', id from stock loop
    perform public.tcg_sync(r.k, r.id);
  end loop;
end $$;

-- =====================================================================
-- 5j) CROQUIS DE ESCARAMUZAS
-- =====================================================================
-- El croquis trae nombres y credenciales de las integrantes (puede haber menores):
-- solo lo ven y lo editan el súper usuario, el lienzo de la charreada y sus jueces.
create table if not exists public.croquis      (id text primary key, data jsonb not null, created_at timestamptz default now());
create table if not exists public.croquis_foto (id text primary key, data jsonb not null, created_at timestamptz default now());
alter table public.croquis      enable row level security;
alter table public.croquis_foto enable row level security;

create or replace function public.can_croquis(eid text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_super() or exists (
    select 1 from events e where e.id = eid
      and ( public.owns_lienzo(e.data->>'lienzoId')
            or ( public.is_approved() and public.my_data()->>'role' = 'juez'
                 and public.my_data()->>'lienzoId' = e.data->>'lienzoId')))
$$;

drop policy if exists "croquis acceso" on public.croquis;
create policy "croquis acceso" on public.croquis for all
  using (public.can_croquis(croquis.data->>'eventId')) with check (public.can_croquis(croquis.data->>'eventId'));
drop policy if exists "croquis_foto acceso" on public.croquis_foto;
create policy "croquis_foto acceso" on public.croquis_foto for all
  using (public.can_croquis(croquis_foto.data->>'eventId')) with check (public.can_croquis(croquis_foto.data->>'eventId'));
grant select, insert, update, delete on public.croquis, public.croquis_foto to authenticated;

-- =====================================================================
-- CHARRERÍA PRO — Actualización: avisos de calificación
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run. Se puede correr varias veces.
-- =====================================================================

-- Cada persona solo ve sus avisos. Los crea el disparador de abajo: nadie los escribe desde la app.
create table if not exists public.notifs (id text primary key, data jsonb not null, created_at timestamptz default now());
alter table public.notifs enable row level security;
drop policy if exists "notifs lectura" on public.notifs;
create policy "notifs lectura" on public.notifs for select using (notifs.data->>'userId' = auth.uid()::text);
grant select on public.notifs to authenticated;

create or replace function public.notifs_read() returns void
language sql security definer set search_path = public as $$
  update notifs set data = data || '{"read":true}'::jsonb where data->>'userId' = auth.uid()::text and coalesce(data->>'read', 'false') = 'false'
$$;
revoke all on function public.notifs_read() from public, anon;
grant execute on function public.notifs_read() to authenticated;

-- Debe coincidir con scoreAudience() de la app
create or replace function public.trg_notif_score() returns trigger
language plpgsql security definer set search_path = public as $$
declare ev jsonb; t jsonb; uid_ text; s jsonb := new.data; now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  select data into ev from events where id = s->>'eventId';
  if ev is null then return null; end if;
  select x into t from jsonb_array_elements(coalesce(ev->'teams', '[]'::jsonb)) x where x->>'id' = s->>'teamId' limit 1;
  for uid_ in
    select distinct u from (
      select l.data->>'ownerId' u from lienzos l where l.id = ev->>'lienzoId'
      union all select c.data->>'userId' from charros c where ev->>'mode' = 'completo' and c.id = t->>'refId'
      union all select tm.data->>'captainId' from teams tm where ev->>'mode' <> 'completo' and tm.id = t->>'refId'
      union all select c.data->>'userId' from charros c where ev->>'mode' = 'escaramuza' and c.data->>'teamId' = t->>'refId'
      union all select c.data->>'userId'
        from jsonb_array_elements(coalesce(s->'parts', '[]'::jsonb)) p
        join jsonb_array_elements(coalesce(ev->'charros', '[]'::jsonb)) e on e->>'id' = p->>'id'
        join charros c on c.id = e->>'refId'
    ) r where u is not null and u <> '' and u is distinct from s->>'judgeId'
  loop
    insert into notifs (id, data) values (new.id || '~' || uid_, jsonb_build_object('id', new.id || '~' || uid_, 'userId', uid_, 'scoreId', new.id, 'eventId', s->>'eventId', 'teamId', s->>'teamId',
      'faena', s->>'faena', 'teamName', s->>'teamName', 'net', s->'net', 'judgeName', s->>'judgeName', 'evTitle', ev->>'title', 'at', now_ms, 'read', false))
    on conflict (id) do update set data = excluded.data;
  end loop;
  return null;
end $$;
drop trigger if exists trg_notif_score on public.scores;
create trigger trg_notif_score after insert or update on public.scores for each row execute function public.trg_notif_score();

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notifs') then
    alter publication supabase_realtime add table public.notifs;
  end if;
end $$;

-- =====================================================================
-- CHARRERÍA PRO — Actualización: dibujos públicos de la rutina de escaramuzas
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run. Se puede correr varias veces.
-- =====================================================================

-- Solo los dibujos de cada ejercicio, sin nombres ni credenciales: los ve quien abra la hoja oficial.
-- El croquis completo sigue siendo privado. Requiere actualizacion_croquis.sql.
create table if not exists public.croquis_dib (id text primary key, data jsonb not null, created_at timestamptz default now());
alter table public.croquis_dib enable row level security;
drop policy if exists "croquis_dib lectura" on public.croquis_dib;
create policy "croquis_dib lectura" on public.croquis_dib for select using (true);
drop policy if exists "croquis_dib alta" on public.croquis_dib;
create policy "croquis_dib alta" on public.croquis_dib for insert with check (public.can_croquis(croquis_dib.data->>'eventId'));
drop policy if exists "croquis_dib cambio" on public.croquis_dib;
create policy "croquis_dib cambio" on public.croquis_dib for update
  using (public.can_croquis(croquis_dib.data->>'eventId')) with check (public.can_croquis(croquis_dib.data->>'eventId'));
grant select on public.croquis_dib to anon, authenticated;
grant insert, update on public.croquis_dib to authenticated;

-- =====================================================================
-- CHARRERÍA PRO — Actualización: la capitana llena y entrega su croquis
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run. Se puede correr varias veces.
-- Requiere actualizacion_croquis.sql, actualizacion_dibujos.sql y actualizacion_avisos.sql.
-- =====================================================================

-- La capitana es quien tiene la cuenta del equipo inscrito con su referencia oficial
create or replace function public.can_croquis_team(eid text, tid text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.can_croquis(eid) or exists (
    select 1 from events e, jsonb_array_elements(coalesce(e.data->'teams', '[]'::jsonb)) t, teams tm
    where e.id = eid and t->>'id' = tid and tm.id = t->>'refId' and tm.data->>'captainId' = auth.uid()::text)
$$;

-- Croquis: al entregarlo, la capitana ya no lo cambia; el lienzo y sus jueces sí pueden reabrirlo
drop policy if exists "croquis acceso" on public.croquis;
drop policy if exists "croquis lectura" on public.croquis;
create policy "croquis lectura" on public.croquis for select using (public.can_croquis_team(croquis.data->>'eventId', croquis.data->>'teamId'));
drop policy if exists "croquis alta" on public.croquis;
create policy "croquis alta" on public.croquis for insert with check (public.can_croquis_team(croquis.data->>'eventId', croquis.data->>'teamId'));
drop policy if exists "croquis cambio" on public.croquis;
create policy "croquis cambio" on public.croquis for update
  using (public.can_croquis(croquis.data->>'eventId') or (public.can_croquis_team(croquis.data->>'eventId', croquis.data->>'teamId') and coalesce(croquis.data->>'entregadoAt', '') = ''))
  with check (public.can_croquis_team(croquis.data->>'eventId', croquis.data->>'teamId'));
drop policy if exists "croquis baja" on public.croquis;
create policy "croquis baja" on public.croquis for delete using (public.can_croquis(croquis.data->>'eventId'));

drop policy if exists "croquis_foto acceso" on public.croquis_foto;
create policy "croquis_foto acceso" on public.croquis_foto for all
  using (public.can_croquis_team(croquis_foto.data->>'eventId', croquis_foto.data->>'teamId'))
  with check (public.can_croquis_team(croquis_foto.data->>'eventId', croquis_foto.data->>'teamId'));

drop policy if exists "croquis_dib alta" on public.croquis_dib;
create policy "croquis_dib alta" on public.croquis_dib for insert with check (public.can_croquis_team(croquis_dib.data->>'eventId', croquis_dib.data->>'teamId'));
drop policy if exists "croquis_dib cambio" on public.croquis_dib;
create policy "croquis_dib cambio" on public.croquis_dib for update
  using (public.can_croquis_team(croquis_dib.data->>'eventId', croquis_dib.data->>'teamId'))
  with check (public.can_croquis_team(croquis_dib.data->>'eventId', croquis_dib.data->>'teamId'));

-- Aviso al lienzo y a sus jueces cuando la capitana entrega. Debe coincidir con notifCroLocal() de la app
create or replace function public.trg_notif_croquis() returns trigger
language plpgsql security definer set search_path = public as $$
declare ev jsonb; t jsonb; uid_ text; s jsonb := new.data; now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  if coalesce(s->>'entregadoAt', '') = '' then return null; end if;
  if tg_op = 'UPDATE' and coalesce(old.data->>'entregadoAt', '') <> '' then return null; end if;
  select data into ev from events where id = s->>'eventId';
  if ev is null then return null; end if;
  select x into t from jsonb_array_elements(coalesce(ev->'teams', '[]'::jsonb)) x where x->>'id' = s->>'teamId' limit 1;
  for uid_ in
    select l.data->>'ownerId' from lienzos l where l.id = ev->>'lienzoId'
    union select p.id from profiles p where p.data->>'role' = 'juez' and p.data->>'lienzoId' = ev->>'lienzoId'
  loop
    continue when uid_ is null;
    insert into notifs (id, data) values ('cro~' || new.id || '~' || uid_, jsonb_build_object('id', 'cro~' || new.id || '~' || uid_, 'kind', 'croquis', 'userId', uid_, 'eventId', s->>'eventId', 'teamId', s->>'teamId',
      'teamName', t->>'name', 'evTitle', ev->>'title', 'at', now_ms, 'read', false))
    on conflict (id) do update set data = excluded.data;
  end loop;
  return null;
end $$;
drop trigger if exists trg_notif_croquis on public.croquis;
create trigger trg_notif_croquis after insert or update on public.croquis for each row execute function public.trg_notif_croquis();

-- =====================================================================
-- CHARRERÍA PRO — Actualización: pedidos de microchip sin pago falso
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run. Se puede correr varias veces.
-- =====================================================================

-- Todo pedido nace "por pagar" y con el precio vigente, aunque alguien altere la página.
-- Solo el súper usuario o la confirmación del proveedor de pagos lo marcan como pagado.
create or replace function public.trg_chip_order() returns trigger
language plpgsql security definer set search_path = public as $$
declare kit numeric;
begin
  if new.data->>'type' = 'chip_order' and not public.is_super() then
    select coalesce((data->>'kit')::numeric, 699) into kit from settings where id = 'precios';
    new.data := new.data || jsonb_build_object('payStatus', 'por_pagar', 'price', coalesce(kit, 699));
  end if;
  return new;
end $$;
drop trigger if exists trg_chip_order on public.requests;
create trigger trg_chip_order before insert on public.requests for each row execute function public.trg_chip_order();

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

-- =====================================================================
-- CHARRERÍA PRO — Actualización: escaneo de caballo por NFC en la mesa del juez
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run. Se puede correr varias veces.
-- =====================================================================

-- Qué caballo montó cada charro en cada faena. Todos lo ven; solo los jueces del lienzo lo registran,
-- durante la charreada en vivo y solo con caballos de chip validado.
create table if not exists public.horse_rides (id text primary key, data jsonb not null, created_at timestamptz default now());
alter table public.horse_rides enable row level security;

create or replace function public.can_ride(eid text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_approved() and public.my_data()->>'role' = 'juez' and exists (
    select 1 from events e where e.id = eid and e.data->>'status' = 'en_vivo' and e.data->>'lienzoId' = public.my_data()->>'lienzoId')
$$;
create or replace function public.chip_ok(hid text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from horses h where h.id = hid and h.data->>'chipStatus' = 'validado')
$$;

drop policy if exists "horse_rides lectura" on public.horse_rides;
create policy "horse_rides lectura" on public.horse_rides for select using (true);
drop policy if exists "horse_rides alta" on public.horse_rides;
create policy "horse_rides alta" on public.horse_rides for insert with check (
  public.can_ride(horse_rides.data->>'eventId') and horse_rides.data->>'judgeId' = auth.uid()::text and public.chip_ok(horse_rides.data->>'horseId'));
drop policy if exists "horse_rides cambio" on public.horse_rides;
create policy "horse_rides cambio" on public.horse_rides for update using (public.can_ride(horse_rides.data->>'eventId'))
  with check (public.can_ride(horse_rides.data->>'eventId') and horse_rides.data->>'judgeId' = auth.uid()::text and public.chip_ok(horse_rides.data->>'horseId'));
drop policy if exists "horse_rides baja" on public.horse_rides;
create policy "horse_rides baja" on public.horse_rides for delete using (public.can_ride(horse_rides.data->>'eventId'));
grant select on public.horse_rides to anon, authenticated;
grant insert, update, delete on public.horse_rides to authenticated;

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'horse_rides') then
    alter publication supabase_realtime add table public.horse_rides;
  end if;
end $$;

-- =====================================================================
-- 6) SÚPER USUARIO (se crea solo; puedes correr este archivo varias veces)
-- =====================================================================
do $$
declare
  v_email text := 'ranchodejuda@gmail.com';
  v_pass  text := 'CAMBIA_ESTA_CONTRASEÑA';  -- solo se usa al crear la cuenta por primera vez
  v_name  text := 'Súper Usuario';
  v_uid   uuid;
begin
  select id into v_uid from auth.users where email = v_email;

  if v_uid is null then
    v_uid := gen_random_uuid();
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, email_change, email_change_token_new, recovery_token
    ) values (
      '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', v_email,
      extensions.crypt(v_pass, extensions.gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(),
      '', '', '', ''
    );
    insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), v_uid, v_uid::text,
            jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true),
            'email', now(), now(), now());
  end if;

  insert into public.profiles (id, data)
  values (v_uid::text, jsonb_build_object(
    'id', v_uid::text, 'name', v_name, 'email', v_email,
    'role', 'superadmin', 'status', 'aprobado',
    'createdAt', (extract(epoch from now()) * 1000)::bigint))
  on conflict (id) do update set data = excluded.data;
end $$;

-- Comprobación: debe mostrar una fila con role = superadmin
select id, data->>'email' as email, data->>'role' as role, data->>'status' as status
from public.profiles where data->>'role' = 'superadmin';

-- =====================================================================
-- CHARRERÍA PRO — Actualización: liquidaciones de la matriz y hallazgos de Sombra
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run. Se puede correr varias veces.
-- =====================================================================

-- Una liquidación por lienzo y mes. Solo la escribe el motor en el servidor, con la clave secreta.
-- Los montos van en centavos enteros. Las reglas de abajo sellan el reparto en la base: aunque el código
-- cambie, una liquidación que no cumpla 10,000 de cuota y 6 / 5 / 5 / 84 sobre el excedente no entra.
create table if not exists public.matriz_liquidaciones (
  id text primary key,
  lienzo_id text not null references public.lienzos(id),
  periodo text not null check (periodo ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  ingreso_centavos bigint not null check (ingreso_centavos >= 0),
  cuota_centavos bigint not null,
  excedente_centavos bigint not null,
  dueno_centavos bigint not null check (dueno_centavos >= 0),
  computo_centavos bigint not null check (computo_centavos >= 0),
  fondo_centavos bigint not null check (fondo_centavos >= 0),
  lienzo_centavos bigint not null check (lienzo_centavos >= 0),
  data jsonb not null,
  created_at timestamptz default now(),
  constraint matriz_un_cierre unique (lienzo_id, periodo),
  constraint matriz_cuota check (cuota_centavos = least(ingreso_centavos, 1000000)),
  constraint matriz_excedente check (excedente_centavos = ingreso_centavos - cuota_centavos),
  constraint matriz_16 check (dueno_centavos + computo_centavos + fondo_centavos = round(excedente_centavos * 16 / 100.0)),
  constraint matriz_cuadra check (cuota_centavos + dueno_centavos + computo_centavos + fondo_centavos + lienzo_centavos = ingreso_centavos),
  -- Cada parte puede moverse hasta un centavo por el redondeo, nunca más.
  constraint matriz_dueno check (abs(dueno_centavos * 100 - excedente_centavos * 6) < 200),
  constraint matriz_computo check (abs(computo_centavos * 100 - excedente_centavos * 5) < 200),
  constraint matriz_fondo check (abs(fondo_centavos * 100 - excedente_centavos * 5) < 200)
);
alter table public.matriz_liquidaciones enable row level security;

-- Un cierre no se edita ni se borra. Esto también detiene a la clave secreta, que se salta las políticas.
create or replace function public.trg_matriz_inmutable() returns trigger
language plpgsql set search_path = public as $$
begin
  raise exception 'Las liquidaciones cerradas no se pueden cambiar ni borrar';
end $$;
drop trigger if exists matriz_inmutable on public.matriz_liquidaciones;
create trigger matriz_inmutable before update or delete on public.matriz_liquidaciones
  for each row execute function public.trg_matriz_inmutable();
drop trigger if exists matriz_inmutable_vaciar on public.matriz_liquidaciones;
create trigger matriz_inmutable_vaciar before truncate on public.matriz_liquidaciones
  for each statement execute function public.trg_matriz_inmutable();

-- El dueño del lienzo ve sus cierres y el súper usuario ve todos. Desde la app nadie los escribe.
drop policy if exists "matriz lectura" on public.matriz_liquidaciones;
create policy "matriz lectura" on public.matriz_liquidaciones for select
  using (public.is_super() or public.owns_lienzo(matriz_liquidaciones.lienzo_id));
revoke all on public.matriz_liquidaciones from anon, authenticated;
grant select on public.matriz_liquidaciones to authenticated;
grant select on public.matriz_liquidaciones to service_role;

-- Hallazgos de Sombra. Guardan una huella del mensaje, nunca el texto. Solo los ve el súper usuario.
create table if not exists public.sombra_hallazgos (
  id text primary key default gen_random_uuid()::text,
  nivel int not null check (nivel between 1 and 4),
  origen text not null,
  tipo text not null check (tipo in ('texto', 'acceso')),
  data jsonb not null,
  created_at timestamptz default now()
);
alter table public.sombra_hallazgos enable row level security;
drop policy if exists "sombra lectura" on public.sombra_hallazgos;
create policy "sombra lectura" on public.sombra_hallazgos for select using (public.is_super());
revoke all on public.sombra_hallazgos from anon, authenticated;
grant select on public.sombra_hallazgos to authenticated;
grant select, insert on public.sombra_hallazgos to service_role;

-- Transacciones medibles de cada cierre. Un comprobante solo puede usarse una vez, aunque se
-- reporte en otro mes o en otro lienzo.
create table if not exists public.matriz_transacciones (
  id text primary key default gen_random_uuid()::text,
  liquidacion_id text not null references public.matriz_liquidaciones(id),
  lienzo_id text not null references public.lienzos(id),
  periodo text not null,
  referencia text not null check (referencia <> ''),
  monto_centavos bigint not null check (monto_centavos > 0),
  fuente text not null,
  fecha date not null,
  concepto text not null default '',
  created_at timestamptz default now(),
  constraint matriz_comprobante_unico unique (fuente, referencia)
);
alter table public.matriz_transacciones enable row level security;
drop trigger if exists matriz_tx_inmutable on public.matriz_transacciones;
create trigger matriz_tx_inmutable before update or delete on public.matriz_transacciones
  for each row execute function public.trg_matriz_inmutable();
drop trigger if exists matriz_tx_inmutable_vaciar on public.matriz_transacciones;
create trigger matriz_tx_inmutable_vaciar before truncate on public.matriz_transacciones
  for each statement execute function public.trg_matriz_inmutable();
drop policy if exists "matriz tx lectura" on public.matriz_transacciones;
create policy "matriz tx lectura" on public.matriz_transacciones for select
  using (public.is_super() or public.owns_lienzo(matriz_transacciones.lienzo_id));
revoke all on public.matriz_transacciones from anon, authenticated;
grant select on public.matriz_transacciones to authenticated;
grant select on public.matriz_transacciones to service_role;

-- Estado operativo del lienzo. Es aparte de lienzos.data.status, que es la aprobación en la app.
create table if not exists public.matriz_lienzo_estado (
  lienzo_id text primary key references public.lienzos(id),
  estado text not null default 'activo' check (estado in ('activo', 'en_vivo', 'mantenimiento', 'inactivo')),
  ultimo_cierre text,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz default now()
);
alter table public.matriz_lienzo_estado enable row level security;
create or replace function public.trg_matriz_estado_fecha() returns trigger
language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists matriz_estado_fecha on public.matriz_lienzo_estado;
create trigger matriz_estado_fecha before update on public.matriz_lienzo_estado
  for each row execute function public.trg_matriz_estado_fecha();
drop policy if exists "matriz estado lectura" on public.matriz_lienzo_estado;
create policy "matriz estado lectura" on public.matriz_lienzo_estado for select
  using (public.is_super() or public.owns_lienzo(matriz_lienzo_estado.lienzo_id));
revoke all on public.matriz_lienzo_estado from anon, authenticated;
grant select on public.matriz_lienzo_estado to authenticated;
grant select, insert, update on public.matriz_lienzo_estado to service_role;

-- Cierre completo en una sola transacción: liquidación, comprobantes y estado, o nada.
create or replace function public.registrar_cierre(p_liquidacion jsonb, p_transacciones jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_id text := p_liquidacion->>'id';
  v_lienzo text := p_liquidacion->>'lienzo_id';
  v_periodo text := p_liquidacion->>'periodo';
begin
  if (select coalesce(sum((t->>'monto_centavos')::bigint), 0) from jsonb_array_elements(p_transacciones) t)
     <> (p_liquidacion->>'ingreso_centavos')::bigint then
    raise exception 'Las transacciones no suman el ingreso del cierre';
  end if;
  if exists (select 1 from jsonb_array_elements(p_transacciones) t where left(t->>'fecha', 7) <> v_periodo) then
    raise exception 'Hay transacciones fuera del periodo del cierre';
  end if;
  insert into matriz_liquidaciones (id, lienzo_id, periodo, ingreso_centavos, cuota_centavos, excedente_centavos,
    dueno_centavos, computo_centavos, fondo_centavos, lienzo_centavos, data)
  values (v_id, v_lienzo, v_periodo, (p_liquidacion->>'ingreso_centavos')::bigint,
    (p_liquidacion->>'cuota_centavos')::bigint, (p_liquidacion->>'excedente_centavos')::bigint,
    (p_liquidacion->>'dueno_centavos')::bigint, (p_liquidacion->>'computo_centavos')::bigint,
    (p_liquidacion->>'fondo_centavos')::bigint, (p_liquidacion->>'lienzo_centavos')::bigint,
    p_liquidacion->'data');
  insert into matriz_transacciones (liquidacion_id, lienzo_id, periodo, referencia, monto_centavos, fuente, fecha, concepto)
  select v_id, v_lienzo, v_periodo, t->>'referencia', (t->>'monto_centavos')::bigint, t->>'fuente',
    (t->>'fecha')::date, coalesce(t->>'concepto', '')
  from jsonb_array_elements(p_transacciones) t;
  insert into matriz_lienzo_estado (lienzo_id, ultimo_cierre) values (v_lienzo, v_periodo)
  on conflict (lienzo_id) do update set ultimo_cierre = excluded.ultimo_cierre;
end $$;
revoke all on function public.registrar_cierre(jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.registrar_cierre(jsonb, jsonb) to service_role;
-- Nadie inserta directo: así un cierre no puede quedar sin sus comprobantes.
revoke insert on public.matriz_liquidaciones, public.matriz_transacciones from service_role;

-- =====================================================================
-- CHARRERÍA PRO — Actualización: solicitudes del kit de cámaras y de Charros TV
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run. Se puede correr varias veces.
-- =====================================================================

-- Se suma a "requests alta". Cada persona tiene máximo una solicitud pendiente de cada tipo.
-- Una política que consulta su propia tabla falla con 42P17: por eso usa req_pending(), que es security definer.
drop policy if exists "requests charros tv" on public.requests;
create policy "requests charros tv" on public.requests for insert with check (
  requests.data->>'createdBy' = auth.uid()::text
  and requests.data->>'status' = 'pendiente'
  and requests.data->>'type' in ('tv_kit', 'tv_sub')
  and not exists (select 1 where public.req_pending(requests.data->>'type', 'createdBy', auth.uid()::text))
);

-- =====================================================================
-- CHARRERÍA PRO — Actualización: cuenta de público
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run. Se puede correr varias veces.
-- =====================================================================

-- Se suma a "profiles alta": el público se registra activo, sin verificación ni Pro.
drop policy if exists "profiles publico" on public.profiles;
create policy "profiles publico" on public.profiles for insert with check (
  id = auth.uid()::text
  and profiles.data->>'role' = 'publico'
  and profiles.data->>'status' = 'aprobado'
  and coalesce(profiles.data->>'verified', 'false') = 'false'
  and coalesce(profiles.data->>'subscriptionStatus', 'free') = 'free'
);

-- =====================================================================
-- CHARRERÍA PRO — Actualización: equipo del lienzo y bitácora por lienzo
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run. Se puede correr varias veces.
-- =====================================================================

-- Un lienzo lo administran su responsable y hasta 3 personas más (lienzos.data.admins).
create or replace function public.owns_lienzo(lid text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_approved() and exists (
    select 1 from lienzos l
    where l.id = lid and l.data->>'status' = 'aprobado'
      and (l.data->>'ownerId' = auth.uid()::text or coalesce(l.data->'admins', '[]'::jsonb) ? auth.uid()::text))
$$;

-- El dueño original es el único que usa esta política: sin esa condición, un integrante podría ponerse como dueño.
drop policy if exists "lienzos cambio" on public.lienzos;
create policy "lienzos cambio" on public.lienzos for update
  using (public.is_super() or lienzos.data->>'ownerId' = auth.uid()::text)
  with check (public.is_super() or (
    lienzos.data->>'ownerId' = auth.uid()::text
    and (select l.data->>'ownerId' from lienzos l where l.id = lienzos.id) = auth.uid()::text
    and lienzos.data->>'status' = (select l.data->>'status' from lienzos l where l.id = lienzos.id)
    and coalesce(lienzos.data->'admins', '[]'::jsonb) = coalesce((select l.data->'admins' from lienzos l where l.id = lienzos.id), '[]'::jsonb)
    and coalesce(lienzos.data->'pendientes', '[]'::jsonb) = coalesce((select l.data->'pendientes' from lienzos l where l.id = lienzos.id), '[]'::jsonb)));

-- Los integrantes editan el lienzo, pero no cambian su estado, su responsable ni su equipo.
drop policy if exists "lienzos equipo" on public.lienzos;
create policy "lienzos equipo" on public.lienzos for update
  using (coalesce(lienzos.data->'admins', '[]'::jsonb) ? auth.uid()::text)
  with check (coalesce(lienzos.data->'admins', '[]'::jsonb) ? auth.uid()::text
    and lienzos.data->>'status' = (select l.data->>'status' from lienzos l where l.id = lienzos.id)
    and lienzos.data->>'ownerId' = (select l.data->>'ownerId' from lienzos l where l.id = lienzos.id)
    and lienzos.data->'admins' = (select l.data->'admins' from lienzos l where l.id = lienzos.id)
    and coalesce(lienzos.data->'pendientes', '[]'::jsonb) = coalesce((select l.data->'pendientes' from lienzos l where l.id = lienzos.id), '[]'::jsonb));

-- El responsable propone a un integrante y solo el súper usuario le abre el panel. El correo se busca aquí: no se expone a la app.
create or replace function public.lienzo_agregar(lid text, correo text) returns text
language plpgsql security definer set search_path = public as $$
declare l jsonb; pid text; nombre text; a jsonb; q jsonb;
begin
  select data into l from lienzos where id = lid;
  if l is null or not (public.is_super() or l->>'ownerId' = auth.uid()::text) then raise exception 'Solo el responsable del lienzo puede hacerlo'; end if;
  select id, data->>'name' into pid, nombre from profiles where lower(data->>'email') = lower(trim(correo)) limit 1;
  if pid is null then raise exception 'Esa persona primero debe crear su cuenta'; end if;
  a := coalesce(l->'admins', '[]'::jsonb); q := coalesce(l->'pendientes', '[]'::jsonb);
  if pid = l->>'ownerId' or a ? pid or q ? pid then raise exception 'Ya es parte del lienzo'; end if;
  if jsonb_array_length(a) + jsonb_array_length(q) >= 3 then raise exception 'Máximo 4 personas por lienzo'; end if;
  update lienzos set data = data || jsonb_build_object('pendientes', q || to_jsonb(pid),
    'adminNames', coalesce(data->'adminNames', '{}'::jsonb) || jsonb_build_object(pid, nombre)) where id = lid;
  return nombre;
end $$;

create or replace function public.lienzo_decidir(lid text, pid text, ok boolean) returns void
language plpgsql security definer set search_path = public as $$
declare l jsonb;
begin
  if not public.is_super() then raise exception 'Solo el súper usuario autoriza'; end if;
  select data into l from lienzos where id = lid;
  if l is null or not coalesce(l->'pendientes', '[]'::jsonb) ? pid then raise exception 'No hay solicitud pendiente'; end if;
  update lienzos set data = data || jsonb_build_object('pendientes', (data->'pendientes') - pid,
    'admins', case when ok then coalesce(data->'admins', '[]'::jsonb) || to_jsonb(pid) else coalesce(data->'admins', '[]'::jsonb) end,
    'adminNames', case when ok then coalesce(data->'adminNames', '{}'::jsonb) else coalesce(data->'adminNames', '{}'::jsonb) - pid end) where id = lid;
end $$;

create or replace function public.lienzo_quitar(lid text, pid text) returns void
language plpgsql security definer set search_path = public as $$
declare l jsonb;
begin
  select data into l from lienzos where id = lid;
  if l is null or not (public.is_super() or l->>'ownerId' = auth.uid()::text) then raise exception 'Solo el responsable del lienzo puede hacerlo'; end if;
  update lienzos set data = data || jsonb_build_object('admins', coalesce(data->'admins', '[]'::jsonb) - pid,
    'pendientes', coalesce(data->'pendientes', '[]'::jsonb) - pid, 'adminNames', coalesce(data->'adminNames', '{}'::jsonb) - pid) where id = lid;
end $$;
revoke all on function public.lienzo_agregar(text, text) from public, anon;
revoke all on function public.lienzo_quitar(text, text) from public, anon;
revoke all on function public.lienzo_decidir(text, text, boolean) from public, anon;
grant execute on function public.lienzo_decidir(text, text, boolean) to authenticated;
grant execute on function public.lienzo_agregar(text, text) to authenticated;
grant execute on function public.lienzo_quitar(text, text) to authenticated;

-- Una cuenta es charro o escaramuza, no ambos: tiene un solo perfil de competidor.
create or replace function public.tiene_charro(uid text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from charros c where c.data->>'userId' = uid)
$$;
revoke all on function public.tiene_charro(text) from public, anon;
grant execute on function public.tiene_charro(text) to authenticated;
drop policy if exists "charros alta" on public.charros;
create policy "charros alta" on public.charros for insert with check (
  public.is_super() or (charros.data->>'userId' = auth.uid()::text and coalesce(charros.data->>'teamId','') = ''
    and charros.data->'verif' is null and charros.data->'verifKey' is null
    and not public.tiene_charro(auth.uid()::text)));

-- Cada lienzo ve quién hizo qué en su lienzo.
drop policy if exists "audit lienzo" on public.audit;
create policy "audit lienzo" on public.audit for select using (public.owns_lienzo(audit.data->>'lienzoId'));

-- =====================================================================
-- CHARRERÍA PRO — Actualización: un charro en varios equipos
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run y confirma con "Run query".
-- La advertencia aparece porque reemplaza un permiso; no borra datos. Se puede correr varias veces.
-- =====================================================================

-- teamId es el equipo que el charro muestra al público; teamIds son todos sus equipos oficiales.
create or replace function public.equipos_charro(d jsonb) returns jsonb
language sql immutable as $$
  select case when jsonb_typeof(d->'teamIds') = 'array' and jsonb_array_length(d->'teamIds') > 0 then d->'teamIds'
              when coalesce(d->>'teamId', '') <> '' then jsonb_build_array(d->>'teamId')
              else '[]'::jsonb end
$$;

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
    -- El primer equipo es el público; los siguientes se suman sin reemplazarlo.
    update charros set data = data || jsonb_build_object(
      'teamId', coalesce(nullif(data->>'teamId', ''), r->>'teamId'),
      'teamIds', public.equipos_charro(data) || (case when public.equipos_charro(data) ? (r->>'teamId') then '[]'::jsonb else to_jsonb(r->>'teamId') end))
    where id = r->>'charroId';
  elsif decision = 'aprobado' and r->>'type' = 'afiliacion' then
    update teams set data = data || jsonb_build_object('lienzoId', r->>'lienzoId', 'lienzoStatus', 'aprobado') where id = r->>'teamId';
  end if;
end $$;

-- Sale de un equipo sin perder los demás. Si era el público, muestra el siguiente.
create or replace function public.charro_salir(cid text, tid text) returns void
language plpgsql security definer set search_path = public as $$
declare c jsonb; q jsonb;
begin
  select data into c from charros where id = cid for update;
  if c is null then raise exception 'Charro no encontrado'; end if;
  if not (c->>'userId' = auth.uid()::text or public.can_decide_team(tid)) then raise exception 'No tienes permiso para esta acción'; end if;
  q := public.equipos_charro(c) - tid;
  update charros set data = data || jsonb_build_object('teamIds', q,
    'teamId', case when c->>'teamId' = tid then q->>0 else c->>'teamId' end) where id = cid;
end $$;

-- El charro elige cuál de sus equipos ve el público. Solo puede elegir uno al que ya pertenece.
create or replace function public.charro_equipo_publico(cid text, tid text) returns void
language plpgsql security definer set search_path = public as $$
declare c jsonb;
begin
  select data into c from charros where id = cid for update;
  if c is null or c->>'userId' is distinct from auth.uid()::text then raise exception 'No tienes permiso para esta acción'; end if;
  if not public.equipos_charro(c) ? tid then raise exception 'No perteneces a ese equipo'; end if;
  update charros set data = data || jsonb_build_object('teamId', tid) where id = cid;
end $$;
revoke all on function public.charro_salir(text, text) from public, anon;
revoke all on function public.charro_equipo_publico(text, text) from public, anon;
grant execute on function public.charro_salir(text, text) to authenticated;
grant execute on function public.charro_equipo_publico(text, text) to authenticated;

-- El charro edita su perfil, pero no se agrega equipos por su cuenta.
drop policy if exists "charros cambio" on public.charros;
create policy "charros cambio" on public.charros for update
  using (public.is_super() or charros.data->>'userId' = auth.uid()::text)
  with check (public.is_super() or (
    charros.data->>'userId' = auth.uid()::text
    and coalesce(charros.data->>'teamId','') = coalesce((select c.data->>'teamId' from charros c where c.id = charros.id),'')
    and coalesce(charros.data->'teamIds','[]'::jsonb) = coalesce((select c.data->'teamIds' from charros c where c.id = charros.id),'[]'::jsonb)
    and public.verif_of(charros.data) = public.verif_of((select c.data from charros c where c.id = charros.id))));

-- =====================================================================
-- CHARRERÍA PRO — Actualización: juego de CharreríaTCG
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run y confirma con "Run query".
-- La advertencia aparece porque reemplaza permisos; no borra datos. Se puede correr varias veces.
-- Las cartas, los premios y las partidas en línea se deciden aquí para que nadie los altere desde el navegador.
-- =====================================================================

create table if not exists public.tcg_catalogo (id text primary key, data jsonb not null);
create table if not exists public.tcg_mis_cartas (id text primary key, data jsonb not null, created_at timestamptz default now());
create table if not exists public.tcg_jugadores (id text primary key, data jsonb not null, created_at timestamptz default now());
create table if not exists public.tcg_partidas (id text primary key, data jsonb not null, created_at timestamptz default now());
create table if not exists public.tcg_jugadas (partida text not null, jugador text not null, c text not null, h text, primary key (partida, jugador));
create table if not exists public.tcg_codigos (id text primary key, data jsonb not null, created_at timestamptz default now());
alter table public.tcg_catalogo enable row level security;
alter table public.tcg_mis_cartas enable row level security;
alter table public.tcg_jugadores enable row level security;
alter table public.tcg_partidas enable row level security;
alter table public.tcg_jugadas enable row level security;   -- sin políticas: nadie lee la jugada secreta del rival
alter table public.tcg_codigos enable row level security;

insert into public.tcg_catalogo (id, data) values
('c01','{"id": "c01", "tipo": "charro", "nombre": "Pancho Novato", "tier": "basica", "reata": 3, "rienda": 3, "jineteo": 2}'::jsonb),
('c02','{"id": "c02", "tipo": "charro", "nombre": "Lupe Aprendiz", "tier": "basica", "reata": 3, "rienda": 2, "jineteo": 3}'::jsonb),
('c03','{"id": "c03", "tipo": "charro", "nombre": "Toñito Rancho", "tier": "basica", "reata": 2, "rienda": 3, "jineteo": 3}'::jsonb),
('c04','{"id": "c04", "tipo": "charro", "nombre": "Beto Corral", "tier": "basica", "reata": 4, "rienda": 2, "jineteo": 2}'::jsonb),
('c05','{"id": "c05", "tipo": "charro", "nombre": "Ramón Potrero", "tier": "basica", "reata": 2, "rienda": 4, "jineteo": 2}'::jsonb),
('c06','{"id": "c06", "tipo": "charro", "nombre": "Goyito Silla", "tier": "basica", "reata": 2, "rienda": 2, "jineteo": 4}'::jsonb),
('c07','{"id": "c07", "tipo": "charro", "nombre": "Chente Campo", "tier": "basica", "reata": 3, "rienda": 3, "jineteo": 3}'::jsonb),
('c08','{"id": "c08", "tipo": "charro", "nombre": "Nacho Lazada", "tier": "basica", "reata": 4, "rienda": 3, "jineteo": 1}'::jsonb),
('c09','{"id": "c09", "tipo": "charro", "nombre": "Memín Soga", "tier": "basica", "reata": 3, "rienda": 4, "jineteo": 1}'::jsonb),
('c10','{"id": "c10", "tipo": "charro", "nombre": "Julián Cerca", "tier": "basica", "reata": 1, "rienda": 3, "jineteo": 4}'::jsonb),
('c11','{"id": "c11", "tipo": "charro", "nombre": "Rafa Establo", "tier": "basica", "reata": 3, "rienda": 2, "jineteo": 3}'::jsonb),
('c12','{"id": "c12", "tipo": "charro", "nombre": "Tacho Pastura", "tier": "basica", "reata": 2, "rienda": 3, "jineteo": 3}'::jsonb),
('c13','{"id": "c13", "tipo": "charro", "nombre": "Chuy Lazadas", "tier": "bronce", "reata": 6, "rienda": 4, "jineteo": 2}'::jsonb),
('c14','{"id": "c14", "tipo": "charro", "nombre": "Toño Rienditas", "tier": "bronce", "reata": 3, "rienda": 6, "jineteo": 3}'::jsonb),
('c15','{"id": "c15", "tipo": "charro", "nombre": "Memo Aguante", "tier": "bronce", "reata": 2, "rienda": 4, "jineteo": 6}'::jsonb),
('c16','{"id": "c16", "tipo": "charro", "nombre": "Paco Pialín", "tier": "bronce", "reata": 6, "rienda": 3, "jineteo": 3}'::jsonb),
('c17','{"id": "c17", "tipo": "charro", "nombre": "Lalo Galope", "tier": "bronce", "reata": 4, "rienda": 6, "jineteo": 2}'::jsonb),
('c18','{"id": "c18", "tipo": "charro", "nombre": "Rudy Montado", "tier": "bronce", "reata": 3, "rienda": 3, "jineteo": 6}'::jsonb),
('c19','{"id": "c19", "tipo": "charro", "nombre": "Nico Soguilla", "tier": "bronce", "reata": 5, "rienda": 4, "jineteo": 3}'::jsonb),
('c20','{"id": "c20", "tipo": "charro", "nombre": "Beto Estribo", "tier": "bronce", "reata": 4, "rienda": 5, "jineteo": 3}'::jsonb),
('c21','{"id": "c21", "tipo": "charro", "nombre": "Quique Brinco", "tier": "bronce", "reata": 4, "rienda": 3, "jineteo": 5}'::jsonb),
('c22','{"id": "c22", "tipo": "charro", "nombre": "Tavo Parejo", "tier": "bronce", "reata": 4, "rienda": 4, "jineteo": 4}'::jsonb),
('c23','{"id": "c23", "tipo": "charro", "nombre": "Lencho Reatazo", "tier": "plata", "reata": 8, "rienda": 4, "jineteo": 3}'::jsonb),
('c24','{"id": "c24", "tipo": "charro", "nombre": "Chema Espuela", "tier": "plata", "reata": 4, "rienda": 8, "jineteo": 3}'::jsonb),
('c25','{"id": "c25", "tipo": "charro", "nombre": "Goyo Bronco", "tier": "plata", "reata": 3, "rienda": 4, "jineteo": 8}'::jsonb),
('c26','{"id": "c26", "tipo": "charro", "nombre": "Santi Floreo", "tier": "plata", "reata": 7, "rienda": 5, "jineteo": 3}'::jsonb),
('c27','{"id": "c27", "tipo": "charro", "nombre": "Mateo Freno", "tier": "plata", "reata": 5, "rienda": 7, "jineteo": 3}'::jsonb),
('c28','{"id": "c28", "tipo": "charro", "nombre": "Ramiro Toretes", "tier": "plata", "reata": 3, "rienda": 5, "jineteo": 7}'::jsonb),
('c29','{"id": "c29", "tipo": "charro", "nombre": "Fermín Cabal", "tier": "plata", "reata": 5, "rienda": 5, "jineteo": 5}'::jsonb),
('c30','{"id": "c30", "tipo": "charro", "nombre": "Nacho Ligero", "tier": "plata", "reata": 6, "rienda": 6, "jineteo": 3}'::jsonb),
('c31','{"id": "c31", "tipo": "charro", "nombre": "El Zurdo de la Loma", "tier": "oro", "reata": 9, "rienda": 5, "jineteo": 4}'::jsonb),
('c32','{"id": "c32", "tipo": "charro", "nombre": "Don Crispín", "tier": "oro", "reata": 5, "rienda": 9, "jineteo": 4}'::jsonb),
('c33','{"id": "c33", "tipo": "charro", "nombre": "Tiburcio Trueno", "tier": "oro", "reata": 4, "rienda": 5, "jineteo": 9}'::jsonb),
('c34','{"id": "c34", "tipo": "charro", "nombre": "El Güero Sogas", "tier": "oro", "reata": 8, "rienda": 6, "jineteo": 4}'::jsonb),
('c35','{"id": "c35", "tipo": "charro", "nombre": "Rosendo Valiente", "tier": "oro", "reata": 6, "rienda": 6, "jineteo": 6}'::jsonb),
('c36','{"id": "c36", "tipo": "charro", "nombre": "Don Maximino", "tier": "oro", "reata": 8, "rienda": 7, "jineteo": 6}'::jsonb),
('h01','{"id": "h01", "tipo": "caballo", "nombre": "Prieto", "tier": "basica", "rienda": 1, "reata": 0, "jineteo": 0}'::jsonb),
('h02','{"id": "h02", "tipo": "caballo", "nombre": "Pinto", "tier": "basica", "rienda": 0, "reata": 1, "jineteo": 0}'::jsonb),
('h03','{"id": "h03", "tipo": "caballo", "nombre": "Tostado", "tier": "basica", "rienda": 1, "reata": 0, "jineteo": 0}'::jsonb),
('h04','{"id": "h04", "tipo": "caballo", "nombre": "Rucio", "tier": "basica", "rienda": 0, "reata": 1, "jineteo": 0}'::jsonb),
('h05','{"id": "h05", "tipo": "caballo", "nombre": "Canelita", "tier": "basica", "rienda": 1, "reata": 1, "jineteo": 0}'::jsonb),
('h06','{"id": "h06", "tipo": "caballo", "nombre": "Bayito", "tier": "basica", "rienda": 1, "reata": 0, "jineteo": 0}'::jsonb),
('h07','{"id": "h07", "tipo": "caballo", "nombre": "Canelo Viejo", "tier": "bronce", "rienda": 1, "reata": 1, "jineteo": 0}'::jsonb),
('h08','{"id": "h08", "tipo": "caballo", "nombre": "Tordillo", "tier": "bronce", "rienda": 2, "reata": 0, "jineteo": 0}'::jsonb),
('h09','{"id": "h09", "tipo": "caballo", "nombre": "Pinolillo", "tier": "bronce", "rienda": 0, "reata": 2, "jineteo": 0}'::jsonb),
('h10','{"id": "h10", "tipo": "caballo", "nombre": "Sombra", "tier": "bronce", "rienda": 1, "reata": 1, "jineteo": 0}'::jsonb),
('h11','{"id": "h11", "tipo": "caballo", "nombre": "Relámpago Bayo", "tier": "plata", "rienda": 3, "reata": 0, "jineteo": 0}'::jsonb),
('h12','{"id": "h12", "tipo": "caballo", "nombre": "Cuerdas", "tier": "plata", "rienda": 0, "reata": 3, "jineteo": 0}'::jsonb),
('h13','{"id": "h13", "tipo": "caballo", "nombre": "Mezquite", "tier": "plata", "rienda": 2, "reata": 1, "jineteo": 0}'::jsonb),
('h14','{"id": "h14", "tipo": "caballo", "nombre": "Alba", "tier": "plata", "rienda": 1, "reata": 2, "jineteo": 0}'::jsonb),
('h15','{"id": "h15", "tipo": "caballo", "nombre": "Rey de Copas", "tier": "oro", "rienda": 3, "reata": 1, "jineteo": 0}'::jsonb),
('h16','{"id": "h16", "tipo": "caballo", "nombre": "Tempestad", "tier": "oro", "rienda": 1, "reata": 3, "jineteo": 0}'::jsonb)
on conflict (id) do update set data = excluded.data;

insert into public.settings (id, data) values ('tcg_banco', '{"id":"tcg_banco","plata":100,"oro":50}'::jsonb) on conflict (id) do nothing;

drop policy if exists "tcg catalogo lectura" on public.tcg_catalogo;
create policy "tcg catalogo lectura" on public.tcg_catalogo for select using (true);
drop policy if exists "tcg jugadores lectura" on public.tcg_jugadores;
create policy "tcg jugadores lectura" on public.tcg_jugadores for select using (true);
drop policy if exists "tcg cartas lectura" on public.tcg_mis_cartas;
create policy "tcg cartas lectura" on public.tcg_mis_cartas for select using (public.is_super() or tcg_mis_cartas.data->>'ownerId' = auth.uid()::text);
drop policy if exists "tcg partidas lectura" on public.tcg_partidas;
create policy "tcg partidas lectura" on public.tcg_partidas for select using (public.is_super() or auth.uid()::text in (tcg_partidas.data->>'a', tcg_partidas.data->>'b'));
drop policy if exists "tcg codigos lectura" on public.tcg_codigos;
create policy "tcg codigos lectura" on public.tcg_codigos for select using (public.is_super());
grant select on public.tcg_catalogo, public.tcg_jugadores, public.tcg_mis_cartas, public.tcg_partidas to anon, authenticated;
grant select on public.tcg_codigos to authenticated;

create or replace function public.tcg_uid() returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.is_approved() then raise exception 'Inicia sesión para jugar'; end if;
  return auth.uid()::text;
end $$;

create or replace function public.tcg_codigo_nuevo(pre text) returns text
language sql volatile as $$ select pre || '-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8)) $$;

create or replace function public.tcg_dar(uid text, cid text, origen text) returns text
language plpgsql security definer set search_path = public as $$
declare i text := 'm' || substr(md5(random()::text || clock_timestamp()::text), 1, 14);
begin
  insert into tcg_mis_cartas (id, data) values (i, jsonb_build_object('id', i, 'ownerId', uid, 'cardId', cid, 'origen', origen, 'at', (extract(epoch from now()) * 1000)::bigint));
  return cid;
end $$;

create or replace function public.tcg_al_azar(t text) returns text
language sql volatile set search_path = public as $$ select id from tcg_catalogo where data->>'tier' = t order by random() limit 1 $$;

-- Primera vez: 8 charros y 4 caballos básicos.
create or replace function public.tcg_inicio() returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid text := public.tcg_uid(); j jsonb; r record; nom text;
begin
  select data into j from tcg_jugadores where id = uid for update;
  if j is not null then return j; end if;
  select data->>'name' into nom from profiles where id = uid;
  j := jsonb_build_object('id', uid, 'name', coalesce(nom, 'Jugador'), 'partidas', 0, 'victorias', 0, 'puntos', 0, 'dia', '', 'premiosDia', 0);
  insert into tcg_jugadores (id, data) values (uid, j);
  for r in select id from tcg_catalogo where data->>'tier' = 'basica' and data->>'tipo' = 'charro' order by random() limit 8 loop perform public.tcg_dar(uid, r.id, 'inicial'); end loop;
  for r in select id from tcg_catalogo where data->>'tier' = 'basica' and data->>'tipo' = 'caballo' order by random() limit 4 loop perform public.tcg_dar(uid, r.id, 'inicial'); end loop;
  return j;
end $$;

-- Máximo 6 cartas de regalo al día. Al ganar siempre hay carta; 15% de ser bronce. Al perder, 30% de básica.
create or replace function public.tcg_resultado(uid text, gano boolean, pts int) returns text
language plpgsql security definer set search_path = public as $$
declare j jsonb; hoy text := current_date::text; n int; cid text;
begin
  select data into j from tcg_jugadores where id = uid for update;
  if j is null then return null; end if;
  n := case when j->>'dia' = hoy then (j->>'premiosDia')::int else 0 end;
  if n < 6 and (gano or random() < .3) then
    cid := public.tcg_dar(uid, public.tcg_al_azar(case when gano and random() < .15 then 'bronce' else 'basica' end), 'regalo');
    n := n + 1;
  end if;
  update tcg_jugadores set data = data || jsonb_build_object('dia', hoy, 'premiosDia', n, 'partidas', (j->>'partidas')::int + 1,
    'victorias', (j->>'victorias')::int + gano::int, 'puntos', (j->>'puntos')::int + case when n < 6 or cid is not null then pts else 0 end) where id = uid;
  return cid;
end $$;

-- La partida contra la IA corre en el navegador: por eso sus premios tienen tope diario.
create or replace function public.tcg_premio(p_gano boolean, p_nivel int) returns text
language plpgsql security definer set search_path = public as $$
declare uid text := public.tcg_uid();
begin
  perform public.tcg_inicio();
  return public.tcg_resultado(uid, p_gano, 1 + case when p_gano then least(greatest(p_nivel, 1), 3) else 0 end);
end $$;

create or replace function public.tcg_faena(i int) returns jsonb
language sql immutable as $$
  select ('[{"stat":"rienda","caballo":true,"s":1,"b":0},{"stat":"reata","caballo":true,"s":1,"b":0},{"stat":"rienda","caballo":true,"s":1,"b":0},{"stat":"jineteo","caballo":false,"s":1,"b":6},{"stat":"reata","caballo":false,"s":1,"b":0},{"stat":"reata","caballo":true,"s":1,"b":0},{"stat":"jineteo","caballo":true,"s":3,"b":7}]'::jsonb)->i
$$;

-- Un mazo son 8 charros y 4 caballos propios, sin repetir y con costo máximo de 20.
create or replace function public.tcg_mazo_ok(uid text, m jsonb) returns void
language plpgsql stable security definer set search_path = public as $$
declare nc int; nh int; costo int; propias int;
begin
  select count(*) filter (where c.data->>'tipo' = 'charro'), count(*) filter (where c.data->>'tipo' = 'caballo'),
         coalesce(sum(case c.data->>'tier' when 'plata' then 2 when 'oro' then 3 else 1 end), 0)
    into nc, nh, costo from tcg_catalogo c where c.id in (select distinct jsonb_array_elements_text(m));
  select count(distinct x.v) into propias from jsonb_array_elements_text(m) x(v)
    where exists (select 1 from tcg_mis_cartas k where k.data->>'ownerId' = uid and k.data->>'cardId' = x.v);
  if nc <> 8 or nh <> 4 or jsonb_array_length(m) <> 12 or costo > 20 or propias <> 12 then raise exception 'Tu mazo no es válido'; end if;
end $$;

create or replace function public.tcg_crear_partida(p_modo text, p_faena int, p_mazo jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare uid text := public.tcg_uid(); i text := 'p' || substr(md5(random()::text || clock_timestamp()::text), 1, 14); cod text := public.tcg_codigo_nuevo('RETA'); nom text;
begin
  perform public.tcg_inicio();
  if p_modo not in ('charreada', 'suerte') or p_faena not between 0 and 6 then raise exception 'Modo inválido'; end if;
  perform public.tcg_mazo_ok(uid, p_mazo);
  select data->>'name' into nom from tcg_jugadores where id = uid;
  insert into tcg_partidas (id, data) values (i, jsonb_build_object('id', i, 'codigo', cod, 'modo', p_modo, 'faena', p_faena, 'a', uid, 'aNombre', nom, 'b', null, 'estado', 'esperando',
    'ronda', 0, 'mazoA', p_mazo, 'usadosA', '[]'::jsonb, 'usadosB', '[]'::jsonb, 'listoA', false, 'listoB', false, 'sa', 0, 'sb', 0, 'bote', 0, 'log', '[]'::jsonb, 'at', (extract(epoch from now()) * 1000)::bigint));
  return i;
end $$;

create or replace function public.tcg_unirse(p_codigo text, p_mazo jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare uid text := public.tcg_uid(); p record; nom text;
begin
  perform public.tcg_inicio();
  select id, data into p from tcg_partidas where data->>'codigo' = upper(trim(p_codigo)) and data->>'estado' = 'esperando' for update;
  if p.id is null then raise exception 'Código inválido o partida ya iniciada'; end if;
  if p.data->>'a' = uid then raise exception 'No puedes jugar contra ti mismo'; end if;
  perform public.tcg_mazo_ok(uid, p_mazo);
  select data->>'name' into nom from tcg_jugadores where id = uid;
  update tcg_partidas set data = data || jsonb_build_object('b', uid, 'bNombre', nom, 'mazoB', p_mazo, 'estado', 'jugando') where id = p.id;
  return p.id;
end $$;

create or replace function public.tcg_valor(cid text, hid text, f jsonb) returns int
language plpgsql stable set search_path = public as $$
declare st text := f->>'stat'; c jsonb; h jsonb; hs text;
begin
  select data into c from tcg_catalogo where id = cid;
  if hid is not null then select data into h from tcg_catalogo where id = hid; end if;
  hs := case when st = 'jineteo' then 'rienda' else st end;
  return (c->>st)::int + coalesce((h->>hs)::int, 0);
end $$;

create or replace function public.tcg_jugar(p_id text, p_c text, p_h text) returns void
language plpgsql security definer set search_path = public as $$
declare uid text := public.tcg_uid(); p jsonb; lado text; f jsonb; ja record; jb record; ta int; tb int; oa boolean; ob boolean; s int; bote int; w text; sa int; sb int; ronda int; total int; suertes int[] := array[-2,-2,-2,0,0,0,1,1,1,2,2,2,4,4,4,6]; ua int; ub int; ganador text;
begin
  select data into p from tcg_partidas where id = p_id for update;
  if p is null or p->>'estado' <> 'jugando' then raise exception 'La partida no está activa'; end if;
  lado := case uid when p->>'a' then 'A' when p->>'b' then 'B' else null end;
  if lado is null then raise exception 'No juegas en esta partida'; end if;
  if (p->('listo' || lado))::text = 'true' then raise exception 'Ya jugaste esta faena'; end if;
  ronda := (p->>'ronda')::int; total := case when p->>'modo' = 'suerte' then 3 else 7 end;
  f := public.tcg_faena(case when p->>'modo' = 'suerte' then (p->>'faena')::int else ronda end);
  if not (p->('mazo' || lado)) ? p_c or p->('usados' || lado) ? p_c or left(p_c, 1) <> 'c' then raise exception 'Esa carta no está disponible'; end if;
  if p_h is not null and (not (f->>'caballo')::boolean or not (p->('mazo' || lado)) ? p_h or p->('usados' || lado) ? p_h or left(p_h, 1) <> 'h') then raise exception 'Ese caballo no está disponible'; end if;
  insert into tcg_jugadas values (p_id, uid, p_c, p_h) on conflict (partida, jugador) do update set c = excluded.c, h = excluded.h;
  p := p || jsonb_build_object('listo' || lado, true, 'usados' || lado, (p->('usados' || lado)) || to_jsonb(p_c) || case when p_h is null then '[]'::jsonb else to_jsonb(p_h) end);
  if (p->'listoA')::text = 'true' and (p->'listoB')::text = 'true' then
    select * into ja from tcg_jugadas where partida = p_id and jugador = p->>'a';
    select * into jb from tcg_jugadas where partida = p_id and jugador = p->>'b';
    ua := suertes[1 + floor(random() * 16)::int]; ub := suertes[1 + floor(random() * 16)::int];
    ta := public.tcg_valor(ja.c, ja.h, f) + ua; tb := public.tcg_valor(jb.c, jb.h, f) + ub;
    oa := ta >= (f->>'b')::int; ob := tb >= (f->>'b')::int;
    s := case when p->>'modo' = 'suerte' then 1 else (f->>'s')::int end; bote := (p->>'bote')::int + s; sa := (p->>'sa')::int; sb := (p->>'sb')::int;
    w := case when oa and not ob then 'a' when ob and not oa then 'b' when oa and ob and ta > tb then 'a' when oa and ob and tb > ta then 'b' else null end;
    if w = 'a' then sa := sa + bote; bote := 0; elsif w = 'b' then sb := sb + bote; bote := 0; end if;
    p := p || jsonb_build_object('sa', sa, 'sb', sb, 'bote', bote, 'ronda', ronda + 1, 'listoA', false, 'listoB', false,
      'log', (p->'log') || jsonb_build_array(jsonb_build_object('ronda', ronda, 'ca', ja.c, 'ha', ja.h, 'cb', jb.c, 'hb', jb.h, 'ua', ua, 'ub', ub, 'ta', ta, 'tb', tb, 'w', w)));
    delete from tcg_jugadas where partida = p_id;
    if ronda + 1 >= total then
      ganador := case when sa > sb then p->>'a' when sb > sa then p->>'b' else null end;
      p := p || jsonb_build_object('estado', 'fin', 'ganador', ganador);
      perform public.tcg_resultado(p->>'a', ganador = p->>'a', case when ganador = p->>'a' then 10 else 2 end);
      perform public.tcg_resultado(p->>'b', ganador = p->>'b', case when ganador = p->>'b' then 10 else 2 end);
    end if;
  end if;
  update tcg_partidas set data = p where id = p_id;
end $$;

create or replace function public.tcg_abandonar(p_id text) returns void
language plpgsql security definer set search_path = public as $$
declare uid text := public.tcg_uid(); p jsonb; otro text;
begin
  select data into p from tcg_partidas where id = p_id for update;
  if p is null or uid not in (p->>'a', coalesce(p->>'b', '')) then raise exception 'No juegas en esta partida'; end if;
  if p->>'estado' = 'fin' then return; end if;
  otro := case when uid = p->>'a' then p->>'b' else p->>'a' end;
  update tcg_partidas set data = data || jsonb_build_object('estado', 'fin', 'ganador', otro, 'abandono', uid) where id = p_id;
  delete from tcg_jugadas where partida = p_id;
end $$;

-- Intercambio: como con los caballos, el dueño genera un código y quien lo escribe recibe la carta.
create or replace function public.tcg_transferir(p_id text) returns text
language plpgsql security definer set search_path = public as $$
declare uid text := public.tcg_uid(); k jsonb; cod text := public.tcg_codigo_nuevo('CARTA'); tipo text; quedan int;
begin
  select data into k from tcg_mis_cartas where id = p_id for update;
  if k is null or k->>'ownerId' <> uid then raise exception 'Esa carta no es tuya'; end if;
  select data->>'tipo' into tipo from tcg_catalogo where id = k->>'cardId';
  select count(distinct m.data->>'cardId') into quedan from tcg_mis_cartas m join tcg_catalogo c on c.id = m.data->>'cardId'
    where m.data->>'ownerId' = uid and m.id <> p_id and c.data->>'tipo' = tipo;
  if quedan < (case when tipo = 'charro' then 8 else 4 end) then raise exception 'Necesitas conservar 8 charros y 4 caballos distintos para jugar'; end if;
  update tcg_mis_cartas set data = data || jsonb_build_object('codigo', cod) where id = p_id;
  return cod;
end $$;

create or replace function public.tcg_recibir(p_codigo text) returns text
language plpgsql security definer set search_path = public as $$
declare uid text := public.tcg_uid(); r record; c text := upper(trim(p_codigo));
begin
  perform public.tcg_inicio();
  select id, data into r from tcg_mis_cartas where data->>'codigo' = c for update;
  if r.id is not null then
    if r.data->>'ownerId' = uid then raise exception 'Esa carta ya es tuya'; end if;
    update tcg_mis_cartas set data = (data - 'codigo') || jsonb_build_object('ownerId', uid, 'origen', 'intercambio') where id = r.id;
    return r.data->>'cardId';
  end if;
  select id, data into r from tcg_codigos where id = c for update;
  if r.id is null or (r.data->>'usado')::boolean then raise exception 'Código inválido o ya usado'; end if;
  update tcg_codigos set data = data || jsonb_build_object('usado', true, 'usadoPor', uid) where id = r.id;
  return public.tcg_dar(uid, r.data->>'cardId', 'impresa');
end $$;

-- Código de una carta impresa. Solo lo genera el súper usuario.
create or replace function public.tcg_crear_codigo(p_carta text) returns text
language plpgsql security definer set search_path = public as $$
declare cod text := public.tcg_codigo_nuevo('REAL');
begin
  if not public.is_super() then raise exception 'Solo el súper usuario'; end if;
  if not exists (select 1 from tcg_catalogo where id = p_carta) then raise exception 'Carta desconocida'; end if;
  insert into tcg_codigos (id, data) values (cod, jsonb_build_object('id', cod, 'cardId', p_carta, 'usado', false));
  return cod;
end $$;

-- Reparte plata y oro a los mejores por puntos. El banco nunca entrega más de 100 de plata ni 50 de oro.
create or replace function public.tcg_repartir(p_plata int, p_oro int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b jsonb; pl int; ou int; r record; dp int := 0; d_o int := 0;
begin
  if not public.is_super() then raise exception 'Solo el súper usuario'; end if;
  select data into b from settings where id = 'tcg_banco' for update;
  pl := least(greatest(p_plata, 0), (b->>'plata')::int); ou := least(greatest(p_oro, 0), (b->>'oro')::int);
  for r in select id from tcg_jugadores order by (data->>'puntos')::int desc, (data->>'partidas')::int desc limit greatest(pl, ou) loop
    if dp < pl then perform public.tcg_dar(r.id, public.tcg_al_azar('plata'), 'premio'); dp := dp + 1; end if;
    if d_o < ou then perform public.tcg_dar(r.id, public.tcg_al_azar('oro'), 'premio'); d_o := d_o + 1; end if;
  end loop;
  update settings set data = data || jsonb_build_object('plata', (b->>'plata')::int - dp, 'oro', (b->>'oro')::int - d_o) where id = 'tcg_banco';
  return jsonb_build_object('plata', dp, 'oro', d_o);
end $$;

do $$
declare f text;
begin
  foreach f in array array['tcg_uid()','tcg_codigo_nuevo(text)','tcg_dar(text,text,text)','tcg_al_azar(text)','tcg_resultado(text,boolean,int)','tcg_mazo_ok(text,jsonb)','tcg_valor(text,text,jsonb)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated';
  end loop;
  foreach f in array array['tcg_inicio()','tcg_premio(boolean,int)','tcg_crear_partida(text,int,jsonb)','tcg_unirse(text,jsonb)','tcg_jugar(text,text,text)','tcg_abandonar(text)','tcg_transferir(text)','tcg_recibir(text)','tcg_crear_codigo(text)','tcg_repartir(int,int)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;

do $$
declare t text;
begin
  foreach t in array array['tcg_mis_cartas','tcg_jugadores','tcg_partidas'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
