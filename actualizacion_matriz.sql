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
grant select on public.matriz_liquidaciones to service_role;

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

-- Transacciones medibles de cada cierre. Un comprobante solo puede usarse una vez, aunque se
-- reporte en otro mes o en otro lienzo.
create table if not exists public.matriz_transacciones (
  id text primary key default gen_random_uuid()::text,
  liquidacion_id text not null references public.matriz_liquidaciones(id),
  lienzo_id text not null references public.lienzos(id),
  periodo text not null,
  referencia text not null check (referencia <> ''),
  monto_centavos bigint not null check (monto_centavos > 0),
  fuente text not null,
  fecha date not null,
  concepto text not null default '',
  created_at timestamptz default now(),
  constraint matriz_comprobante_unico unique (fuente, referencia)
);
alter table public.matriz_transacciones enable row level security;
drop trigger if exists matriz_tx_inmutable on public.matriz_transacciones;
create trigger matriz_tx_inmutable before update or delete on public.matriz_transacciones
  for each row execute function public.trg_matriz_inmutable();
drop trigger if exists matriz_tx_inmutable_vaciar on public.matriz_transacciones;
create trigger matriz_tx_inmutable_vaciar before truncate on public.matriz_transacciones
  for each statement execute function public.trg_matriz_inmutable();
drop policy if exists "matriz tx lectura" on public.matriz_transacciones;
create policy "matriz tx lectura" on public.matriz_transacciones for select
  using (public.is_super() or public.owns_lienzo(matriz_transacciones.lienzo_id));
revoke all on public.matriz_transacciones from anon, authenticated;
grant select on public.matriz_transacciones to authenticated;
grant select on public.matriz_transacciones to service_role;

-- Estado operativo del lienzo. Es aparte de lienzos.data.status, que es la aprobación en la app.
create table if not exists public.matriz_lienzo_estado (
  lienzo_id text primary key references public.lienzos(id),
  estado text not null default 'activo' check (estado in ('activo', 'en_vivo', 'mantenimiento', 'inactivo')),
  ultimo_cierre text,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz default now()
);
alter table public.matriz_lienzo_estado enable row level security;
create or replace function public.trg_matriz_estado_fecha() returns trigger
language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists matriz_estado_fecha on public.matriz_lienzo_estado;
create trigger matriz_estado_fecha before update on public.matriz_lienzo_estado
  for each row execute function public.trg_matriz_estado_fecha();
drop policy if exists "matriz estado lectura" on public.matriz_lienzo_estado;
create policy "matriz estado lectura" on public.matriz_lienzo_estado for select
  using (public.is_super() or public.owns_lienzo(matriz_lienzo_estado.lienzo_id));
revoke all on public.matriz_lienzo_estado from anon, authenticated;
grant select on public.matriz_lienzo_estado to authenticated;
grant select, insert, update on public.matriz_lienzo_estado to service_role;

-- Cierre completo en una sola transacción: liquidación, comprobantes y estado, o nada.
create or replace function public.registrar_cierre(p_liquidacion jsonb, p_transacciones jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_id text := p_liquidacion->>'id';
  v_lienzo text := p_liquidacion->>'lienzo_id';
  v_periodo text := p_liquidacion->>'periodo';
begin
  if (select coalesce(sum((t->>'monto_centavos')::bigint), 0) from jsonb_array_elements(p_transacciones) t)
     <> (p_liquidacion->>'ingreso_centavos')::bigint then
    raise exception 'Las transacciones no suman el ingreso del cierre';
  end if;
  if exists (select 1 from jsonb_array_elements(p_transacciones) t where left(t->>'fecha', 7) <> v_periodo) then
    raise exception 'Hay transacciones fuera del periodo del cierre';
  end if;
  insert into matriz_liquidaciones (id, lienzo_id, periodo, ingreso_centavos, cuota_centavos, excedente_centavos,
    dueno_centavos, computo_centavos, fondo_centavos, lienzo_centavos, data)
  values (v_id, v_lienzo, v_periodo, (p_liquidacion->>'ingreso_centavos')::bigint,
    (p_liquidacion->>'cuota_centavos')::bigint, (p_liquidacion->>'excedente_centavos')::bigint,
    (p_liquidacion->>'dueno_centavos')::bigint, (p_liquidacion->>'computo_centavos')::bigint,
    (p_liquidacion->>'fondo_centavos')::bigint, (p_liquidacion->>'lienzo_centavos')::bigint,
    p_liquidacion->'data');
  insert into matriz_transacciones (liquidacion_id, lienzo_id, periodo, referencia, monto_centavos, fuente, fecha, concepto)
  select v_id, v_lienzo, v_periodo, t->>'referencia', (t->>'monto_centavos')::bigint, t->>'fuente',
    (t->>'fecha')::date, coalesce(t->>'concepto', '')
  from jsonb_array_elements(p_transacciones) t;
  insert into matriz_lienzo_estado (lienzo_id, ultimo_cierre) values (v_lienzo, v_periodo)
  on conflict (lienzo_id) do update set ultimo_cierre = excluded.ultimo_cierre;
end $$;
revoke all on function public.registrar_cierre(jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.registrar_cierre(jsonb, jsonb) to service_role;
-- Nadie inserta directo: así un cierre no puede quedar sin sus comprobantes.
revoke insert on public.matriz_liquidaciones, public.matriz_transacciones from service_role;
