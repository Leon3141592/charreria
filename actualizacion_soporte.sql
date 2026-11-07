-- =====================================================================
-- CHARRERÍA PRO — Actualización: topes diarios de Lupita y Don Lalo
-- Se corre cuando se active la inteligencia artificial. No guarda conversaciones.
-- =====================================================================
create table if not exists public.soporte_uso (dia date primary key, n int not null default 0);
alter table public.soporte_uso enable row level security;   -- sin políticas: solo la función del servidor

create or replace function public.soporte_contar(limite int) returns boolean
language plpgsql security definer set search_path = public as $$
declare total int;
begin
  insert into soporte_uso (dia, n) values (current_date, 1)
  on conflict (dia) do update set n = soporte_uso.n + 1 returning n into total;
  return total <= limite;
end $$;
revoke all on function public.soporte_contar(int) from public, anon, authenticated;
grant execute on function public.soporte_contar(int) to service_role;

-- Tope diario por persona para Don Lalo. Tampoco guarda conversaciones.
create table if not exists public.lalo_uso (dia date not null, usuario text not null, n int not null default 0, primary key (dia, usuario));
alter table public.lalo_uso enable row level security;

create or replace function public.lalo_contar(uid text, limite int) returns boolean
language plpgsql security definer set search_path = public as $$
declare total int;
begin
  insert into lalo_uso (dia, usuario, n) values (current_date, uid, 1)
  on conflict (dia, usuario) do update set n = lalo_uso.n + 1 returning n into total;
  return total <= limite;
end $$;
revoke all on function public.lalo_contar(text, int) from public, anon, authenticated;
grant execute on function public.lalo_contar(text, int) to service_role;

notify pgrst, 'reload schema';
