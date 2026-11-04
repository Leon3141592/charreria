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

notify pgrst, 'reload schema';
select to_regclass('public.horse_rides') as tabla;
