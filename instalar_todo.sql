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
