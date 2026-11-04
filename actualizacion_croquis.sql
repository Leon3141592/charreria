-- =====================================================================
-- CHARRERÍA PRO — Actualización: croquis de escaramuzas (datos y foto de la hoja)
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run. Se puede correr varias veces.
-- =====================================================================

-- El croquis trae nombres y credenciales de las integrantes (puede haber menores):
-- solo lo ven y lo editan el súper usuario, el lienzo de la charreada y sus jueces.
create table if not exists public.croquis      (id text primary key, data jsonb not null, created_at timestamptz default now());
create table if not exists public.croquis_foto (id text primary key, data jsonb not null, created_at timestamptz default now());
alter table public.croquis      enable row level security;
alter table public.croquis_foto enable row level security;

create or replace function public.can_croquis(eid text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_super() or exists (
    select 1 from events e where e.id = eid
      and ( public.owns_lienzo(e.data->>'lienzoId')
            or ( public.is_approved() and public.my_data()->>'role' = 'juez'
                 and public.my_data()->>'lienzoId' = e.data->>'lienzoId')))
$$;

drop policy if exists "croquis acceso" on public.croquis;
create policy "croquis acceso" on public.croquis for all
  using (public.can_croquis(croquis.data->>'eventId')) with check (public.can_croquis(croquis.data->>'eventId'));
drop policy if exists "croquis_foto acceso" on public.croquis_foto;
create policy "croquis_foto acceso" on public.croquis_foto for all
  using (public.can_croquis(croquis_foto.data->>'eventId')) with check (public.can_croquis(croquis_foto.data->>'eventId'));

grant select, insert, update, delete on public.croquis, public.croquis_foto to authenticated;

-- Comprobación: debe mostrar una fila que diga "croquis listo"
select 'croquis listo' as resultado, count(*) as tablas from information_schema.tables where table_schema = 'public' and table_name in ('croquis', 'croquis_foto');
