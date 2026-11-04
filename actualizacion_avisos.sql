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

-- Recarga las tablas de la API y confirma: debe mostrar notifs
notify pgrst, 'reload schema';
select to_regclass('public.notifs') as tabla;
