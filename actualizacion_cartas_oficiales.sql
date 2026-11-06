-- =====================================================================
-- CHARRERÍA PRO — Actualización: cartas oficiales en el juego de CharreríaTCG
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run y confirma con "Run query" si aparece.
-- Se puede correr varias veces.
-- =====================================================================

-- El súper usuario publica la habilidad calculada de cada carta oficial para que el servidor valide partidas.
create or replace function public.tcg_catalogo_subir(p_cartas jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare c jsonb; n int := 0;
begin
  if not public.is_super() then raise exception 'Solo el súper usuario'; end if;
  for c in select * from jsonb_array_elements(p_cartas) loop
    if exists (select 1 from tcg_cards t where t.id = c->>'id') then
      insert into tcg_catalogo (id, data) values (c->>'id', c) on conflict (id) do update set data = excluded.data;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.tcg_catalogo_subir(jsonb) from public, anon;
grant execute on function public.tcg_catalogo_subir(jsonb) to authenticated;

notify pgrst, 'reload schema';

-- Debe mostrar 1 fila.
select proname as instalado from pg_proc where proname = 'tcg_catalogo_subir';
