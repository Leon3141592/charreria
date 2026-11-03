-- =====================================================================
-- CHARRERÍA PRO — Actualización: jueces y lienzos califican el ganado de cada charreada
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run.
-- Requiere actualizacion_ganado.sql. Se puede correr varias veces.
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
