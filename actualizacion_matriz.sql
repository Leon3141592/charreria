-- =====================================================================
-- CHARRERÍA PRO — Actualización: liquidaciones de la matriz y hallazgos de Sombra
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run. Se puede correr varias veces.
-- =====================================================================

-- Una liquidación por lienzo y mes. Solo la escribe el motor en el servidor, con la clave secreta.
-- Los montos van en centavos enteros. Las reglas de abajo sellan el reparto en la base: aunque el código
-- cambie, una liquidación que no cumpla 10,000 de cuota y 6 / 5 / 5 / 84 sobre el excedente no entra.
create table if not exists public.matriz_liquidaciones (
  id text primary key,
  lienzo_id text not null references public.lienzos(id),
  periodo text not null check (periodo ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  ingreso_centavos bigint not null check (ingreso_centavos >= 0),
  cuota_centavos bigint not null,
  excedente_centavos bigint not null,
  dueno_centavos bigint not null check (dueno_centavos >= 0),
  computo_centavos bigint not null check (computo_centavos >= 0),
  fondo_centavos bigint not null check (fondo_centavos >= 0),
  lienzo_centavos bigint not null check (lienzo_centavos >= 0),
  data jsonb not null,
  created_at timestamptz default now(),
  constraint matriz_un_cierre unique (lienzo_id, periodo),
  constraint matriz_cuota check (cuota_centavos = least(ingreso_centavos, 1000000)),
  constraint matriz_excedente check (excedente_centavos = ingreso_centavos - cuota_centavos),
  constraint matriz_16 check (dueno_centavos + computo_centavos + fondo_centavos = round(excedente_centavos * 16 / 100.0)),
  constraint matriz_cuadra check (cuota_centavos + dueno_centavos + computo_centavos + fondo_centavos + lienzo_centavos = ingreso_centavos),
  -- Cada parte puede moverse hasta un centavo por el redondeo, nunca más.
  constraint matriz_dueno check (abs(dueno_centavos * 100 - excedente_centavos * 6) < 200),
  constraint matriz_computo check (abs(computo_centavos * 100 - excedente_centavos * 5) < 200),
  constraint matriz_fondo check (abs(fondo_centavos * 100 - excedente_centavos * 5) < 200)
);
alter table public.matriz_liquidaciones enable row level security;

-- Un cierre no se edita ni se borra. Esto también detiene a la clave secreta, que se salta las políticas.
create or replace function public.trg_matriz_inmutable() returns trigger
language plpgsql set search_path = public as $$
begin
  raise exception 'Las liquidaciones cerradas no se pueden cambiar ni borrar';
end $$;
drop trigger if exists matriz_inmutable on public.matriz_liquidaciones;
create trigger matriz_inmutable before update or delete on public.matriz_liquidaciones
  for each row execute function public.trg_matriz_inmutable();
drop trigger if exists matriz_inmutable_vaciar on public.matriz_liquidaciones;
create trigger matriz_inmutable_vaciar before truncate on public.matriz_liquidaciones
  for each statement execute function public.trg_matriz_inmutable();

-- El dueño del lienzo ve sus cierres y el súper usuario ve todos. Desde la app nadie los escribe.
drop policy if exists "matriz lectura" on public.matriz_liquidaciones;
create policy "matriz lectura" on public.matriz_liquidaciones for select
  using (public.is_super() or public.owns_lienzo(matriz_liquidaciones.lienzo_id));
revoke all on public.matriz_liquidaciones from anon, authenticated;
grant select on public.matriz_liquidaciones to authenticated;
grant select, insert on public.matriz_liquidaciones to service_role;

-- Hallazgos de Sombra. Guardan una huella del mensaje, nunca el texto. Solo los ve el súper usuario.
create table if not exists public.sombra_hallazgos (
  id text primary key default gen_random_uuid()::text,
  nivel int not null check (nivel between 1 and 4),
  origen text not null,
  tipo text not null check (tipo in ('texto', 'acceso')),
  data jsonb not null,
  created_at timestamptz default now()
);
alter table public.sombra_hallazgos enable row level security;
drop policy if exists "sombra lectura" on public.sombra_hallazgos;
create policy "sombra lectura" on public.sombra_hallazgos for select using (public.is_super());
revoke all on public.sombra_hallazgos from anon, authenticated;
grant select on public.sombra_hallazgos to authenticated;
grant select, insert on public.sombra_hallazgos to service_role;
