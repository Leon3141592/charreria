-- =====================================================================
-- CHARRERÍA PRO — Actualización: los jueces reconocen chips registrados por el dueño
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run. Se puede correr varias veces.
-- El ranking oficial sigue contando solo caballos con chip validado.
-- =====================================================================

create or replace function public.chip_ok(hid text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from horses h where h.id = hid and h.data->>'chipStatus' in ('validado', 'pendiente'))
$$;

notify pgrst, 'reload schema';

-- Debe mostrar 1 fila.
select proname as instalado from pg_proc where proname = 'chip_ok';
