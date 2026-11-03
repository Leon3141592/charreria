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
