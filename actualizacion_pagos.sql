-- =====================================================================
-- CHARRERÍA PRO — Actualización: pedidos de microchip sin pago falso
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run. Se puede correr varias veces.
-- =====================================================================

-- Todo pedido nace "por pagar" y con el precio vigente, aunque alguien altere la página.
-- Solo el súper usuario o la confirmación del proveedor de pagos lo marcan como pagado.
create or replace function public.trg_chip_order() returns trigger
language plpgsql security definer set search_path = public as $$
declare kit numeric;
begin
  if new.data->>'type' = 'chip_order' and not public.is_super() then
    select coalesce((data->>'kit')::numeric, 699) into kit from settings where id = 'precios';
    new.data := new.data || jsonb_build_object('payStatus', 'por_pagar', 'price', coalesce(kit, 699));
  end if;
  return new;
end $$;
drop trigger if exists trg_chip_order on public.requests;
create trigger trg_chip_order before insert on public.requests for each row execute function public.trg_chip_order();

select 'pedidos protegidos' as resultado;
