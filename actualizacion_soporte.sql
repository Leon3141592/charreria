-- =====================================================================
-- CHARRERÍA PRO — Actualización: tope diario del chat de servicio al cliente
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

notify pgrst, 'reload schema';
