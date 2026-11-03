-- =====================================================================
-- CHARRERÍA PRO — Actualización: ajustes administrativos del súper usuario
-- (puntos de ranking, valuación de caballos, renta de ganado y destacados)
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run. Se puede correr varias veces.
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
