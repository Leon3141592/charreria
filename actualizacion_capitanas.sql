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

-- Recarga las tablas de la API y confirma: debe mostrar can_croquis_team
notify pgrst, 'reload schema';
select to_regprocedure('public.can_croquis_team(text,text)') as funcion;
