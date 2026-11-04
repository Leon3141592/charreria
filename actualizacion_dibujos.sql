-- =====================================================================
-- CHARRERÍA PRO — Actualización: dibujos públicos de la rutina de escaramuzas
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run. Se puede correr varias veces.
-- =====================================================================

-- Solo los dibujos de cada ejercicio, sin nombres ni credenciales: los ve quien abra la hoja oficial.
-- El croquis completo sigue siendo privado. Requiere actualizacion_croquis.sql.
create table if not exists public.croquis_dib (id text primary key, data jsonb not null, created_at timestamptz default now());
alter table public.croquis_dib enable row level security;
drop policy if exists "croquis_dib lectura" on public.croquis_dib;
create policy "croquis_dib lectura" on public.croquis_dib for select using (true);
drop policy if exists "croquis_dib alta" on public.croquis_dib;
create policy "croquis_dib alta" on public.croquis_dib for insert with check (public.can_croquis(croquis_dib.data->>'eventId'));
drop policy if exists "croquis_dib cambio" on public.croquis_dib;
create policy "croquis_dib cambio" on public.croquis_dib for update
  using (public.can_croquis(croquis_dib.data->>'eventId')) with check (public.can_croquis(croquis_dib.data->>'eventId'));
grant select on public.croquis_dib to anon, authenticated;
grant insert, update on public.croquis_dib to authenticated;

-- Recarga las tablas de la API y confirma: debe mostrar croquis_dib
notify pgrst, 'reload schema';
select to_regclass('public.croquis_dib') as tabla;
