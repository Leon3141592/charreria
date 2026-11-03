-- =====================================================================
-- CHARRERÍA PRO — Actualización: valuación realista, demanda y precio fijado por el súper usuario
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run.
-- Requiere actualizacion_caballos.sql. Se puede correr varias veces.
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
