-- =====================================================================
-- CHARRERÍA PRO — Actualización: ganaderías, toros y yeguas (por unidad o por lote) y renta
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run.
-- Requiere actualizacion_verificacion.sql. Se puede correr varias veces.
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
