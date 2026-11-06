-- =====================================================================
-- CHARRERÍA PRO — Actualización: 3 jueces califican por separado y 2 escanean
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run y confirma con "Run query" si aparece.
-- Se puede correr varias veces. No borra calificaciones. Las charreadas sin jueces asignados siguen igual.
-- =====================================================================

create table if not exists public.scores_juez (id text primary key, data jsonb not null, created_at timestamptz default now());
create table if not exists public.evento_lista (id text primary key, data jsonb not null, created_at timestamptz default now());
alter table public.scores_juez enable row level security;
alter table public.evento_lista enable row level security;

-- La charreada usa el equipo de jueces si el lienzo asignó quién califica.
create or replace function public.event_tres(eid text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from events e, jsonb_array_elements(coalesce(e.data->'jueces', '[]'::jsonb)) j
    where e.id = eid and e.data->>'mode' <> 'escaramuza' and j->>'fn' = 'califica')
$$;

-- Función del juez que entra: califica, escanea o nada. Solo con la charreada en vivo.
create or replace function public.juez_fn(eid text) returns text
language sql stable security definer set search_path = public as $$
  select j->>'fn' from events e, jsonb_array_elements(coalesce(e.data->'jueces', '[]'::jsonb)) j
  where e.id = eid and e.data->>'status' = 'en_vivo' and j->>'id' = auth.uid()::text
    and public.is_approved() and public.my_data()->>'role' = 'juez' and public.my_data()->>'lienzoId' = e.data->>'lienzoId'
  limit 1
$$;

-- Con equipo de jueces, la calificación oficial solo la escribe el servidor.
drop policy if exists "scores alta" on public.scores;
create policy "scores alta" on public.scores for insert with check (
  public.can_score(scores.data->>'eventId') and scores.data->>'judgeId' = auth.uid()::text
  and not public.event_tres(scores.data->>'eventId')
  and (public.is_super() or public.sheet_open(scores.data->>'eventId', scores.data->>'teamId')));
drop policy if exists "scores cambio" on public.scores;
create policy "scores cambio" on public.scores for update
  using (public.can_score(scores.data->>'eventId') and not public.event_tres(scores.data->>'eventId'))
  with check (public.can_score(scores.data->>'eventId') and scores.data->>'judgeId' = auth.uid()::text
    and not public.event_tres(scores.data->>'eventId')
    and (public.is_super() or public.sheet_open(scores.data->>'eventId', scores.data->>'teamId')));

-- Cada juez escribe solo su propia calificación.
drop policy if exists "scores_juez lectura" on public.scores_juez;
create policy "scores_juez lectura" on public.scores_juez for select using (true);
drop policy if exists "scores_juez alta" on public.scores_juez;
create policy "scores_juez alta" on public.scores_juez for insert with check (
  public.juez_fn(scores_juez.data->>'eventId') = 'califica' and scores_juez.data->>'judgeId' = auth.uid()::text
  and scores_juez.id = (scores_juez.data->>'eventId') || '-' || (scores_juez.data->>'teamId') || '-' || (scores_juez.data->>'faena') || '-' || auth.uid()::text
  and public.sheet_open(scores_juez.data->>'eventId', scores_juez.data->>'teamId'));
drop policy if exists "scores_juez cambio" on public.scores_juez;
create policy "scores_juez cambio" on public.scores_juez for update
  using (public.juez_fn(scores_juez.data->>'eventId') = 'califica' and scores_juez.data->>'judgeId' = auth.uid()::text)
  with check (public.juez_fn(scores_juez.data->>'eventId') = 'califica' and scores_juez.data->>'judgeId' = auth.uid()::text
    and scores_juez.id = (scores_juez.data->>'eventId') || '-' || (scores_juez.data->>'teamId') || '-' || (scores_juez.data->>'faena') || '-' || auth.uid()::text
    and public.sheet_open(scores_juez.data->>'eventId', scores_juez.data->>'teamId'));

-- Lista confirmada y cambios de último momento: la escriben los 5 jueces de la charreada.
drop policy if exists "evento_lista lectura" on public.evento_lista;
create policy "evento_lista lectura" on public.evento_lista for select using (true);
drop policy if exists "evento_lista alta" on public.evento_lista;
create policy "evento_lista alta" on public.evento_lista for insert with check (
  public.juez_fn(evento_lista.data->>'eventId') is not null and evento_lista.data->>'byId' = auth.uid()::text);
drop policy if exists "evento_lista cambio" on public.evento_lista;
create policy "evento_lista cambio" on public.evento_lista for update
  using (public.juez_fn(evento_lista.data->>'eventId') is not null)
  with check (public.juez_fn(evento_lista.data->>'eventId') is not null and evento_lista.data->>'byId' = auth.uid()::text);

-- Los 5 jueces pueden corregir nombres, sin tocar nada más de la charreada.
drop policy if exists "events jueces cambian nombre" on public.events;
create policy "events jueces cambian nombre" on public.events for update
  using (public.juez_fn(events.id) is not null)
  with check (
    public.juez_fn(events.id) is not null
    and (events.data - 'charros') = (select e.data - 'charros' from events e where e.id = events.id)
    and (select jsonb_agg(c - 'name' order by c->>'id') from jsonb_array_elements(events.data->'charros') c)
      = (select jsonb_agg(c - 'name' order by c->>'id') from events e, jsonb_array_elements(e.data->'charros') c where e.id = events.id));

-- Cada vez que un juez publica, el servidor saca el promedio. Mismas cuentas que jCombina() en index.html.
create or replace function public.scores_combina() returns trigger
language plpgsql security definer set search_path = public as $$
declare eid text := new.data->>'eventId'; tid text := new.data->>'teamId'; fk text := new.data->>'faena'; b jsonb; n int; partes jsonb; lista jsonb; sid text := eid || '-' || tid || '-' || fk;
begin
  perform pg_advisory_xact_lock(hashtext(sid));
  select data into b from scores_juez where data->>'eventId' = eid and data->>'teamId' = tid and data->>'faena' = fk order by (data->>'judgeN')::int limit 1;
  select count(*), jsonb_agg(jsonb_build_object('id', data->>'judgeId', 'name', data->>'judgeName', 'n', (data->>'judgeN')::int, 'net', (data->>'net')::int) order by (data->>'judgeN')::int)
    into n, lista from scores_juez where data->>'eventId' = eid and data->>'teamId' = tid and data->>'faena' = fk;
  select coalesce(jsonb_agg(p || jsonb_build_object('pts', (
      select floor(avg((x->>'pts')::numeric) + 0.5)::int from scores_juez j, jsonb_array_elements(j.data->'parts') x
      where j.data->>'eventId' = eid and j.data->>'teamId' = tid and j.data->>'faena' = fk and x->>'id' = p->>'id'))), '[]'::jsonb)
    into partes from jsonb_array_elements(b->'parts') p;
  insert into scores (id, data)
  select sid, (b || jsonb_build_object('id', sid, 'parts', partes, 'jueces', lista, 'judgeName', n || ' de 3 jueces', 'updatedAt', (extract(epoch from now()) * 1000)::bigint,
    'buenos', floor(avg((data->>'buenos')::numeric) + 0.5)::int, 'malos', floor(avg((data->>'malos')::numeric) + 0.5)::int,
    'total', floor(avg((data->>'total')::numeric) + 0.5)::int, 'eq', floor(avg(coalesce((data->>'eq')::numeric, 0)) + 0.5)::int, 'net', floor(avg((data->>'net')::numeric) + 0.5)::int)) - 'judgeN' - 'history'
  from scores_juez where data->>'eventId' = eid and data->>'teamId' = tid and data->>'faena' = fk
  on conflict (id) do update set data = excluded.data;
  return new;
end $$;
drop trigger if exists scores_juez_promedio on public.scores_juez;
create trigger scores_juez_promedio after insert or update on public.scores_juez for each row execute function public.scores_combina();

grant select on public.scores_juez, public.evento_lista to anon, authenticated;
grant insert, update on public.scores_juez, public.evento_lista to authenticated;
revoke all on function public.scores_combina() from public, anon, authenticated;

do $$ declare t text; begin
  foreach t in array array['scores_juez', 'evento_lista'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';

-- Debe mostrar 2 tablas.
select count(*) as tablas_nuevas from pg_tables where schemaname = 'public' and tablename in ('scores_juez', 'evento_lista');
