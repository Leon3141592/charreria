-- =====================================================================
-- CHARRERÍA PRO — Actualización: perfiles de charros, equipos y dueños de caballos
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run.
-- Se puede correr varias veces. También está incluido en instalar_todo.sql.
-- =====================================================================

-- 0) Regla anterior: jueces agregan charros de último momento (por si no se había ejecutado)
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
