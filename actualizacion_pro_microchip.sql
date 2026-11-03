-- =====================================================================
-- CHARRERÍA PRO — Actualización: plan Pro (freemium), kit de microchip NFC y carnet digital
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run.
-- Requiere actualizacion_ajustes.sql. Se puede correr varias veces.
-- =====================================================================

-- 1) PRECIOS (los cambia el súper usuario desde la app)
insert into public.settings (id, data) values ('precios', '{"id":"precios","pro":99,"kit":699}'::jsonb)
on conflict (id) do nothing;

-- 2) PLAN PRO: nadie se lo pone editando su perfil; solo con activate_pro() o el súper usuario
drop policy if exists "profiles propio" on public.profiles;
create policy "profiles propio" on public.profiles for update using (id = auth.uid()::text) with check (
  id = auth.uid()::text
  and profiles.data->>'role'   = (select p.data->>'role'   from profiles p where p.id = profiles.id)
  and profiles.data->>'status' = (select p.data->>'status' from profiles p where p.id = profiles.id)
  and coalesce(profiles.data->>'lienzoId','') = coalesce((select p.data->>'lienzoId' from profiles p where p.id = profiles.id),'')
  and coalesce(profiles.data->>'verified','false') = coalesce((select p.data->>'verified' from profiles p where p.id = profiles.id),'false')
  and coalesce(profiles.data->>'subscriptionStatus','free') = coalesce((select p.data->>'subscriptionStatus' from profiles p where p.id = profiles.id),'free')
  and coalesce(profiles.data->>'proUntil','') = coalesce((select p.data->>'proUntil' from profiles p where p.id = profiles.id),''));

drop policy if exists "profiles alta" on public.profiles;
create policy "profiles alta" on public.profiles for insert with check (
  id = auth.uid()::text
  and profiles.data->>'role' in ('lienzo','juez','charro','equipo','dueno','ganadero')
  and coalesce(profiles.data->>'verified','false') = 'false'
  and coalesce(profiles.data->>'subscriptionStatus','free') = 'free'
  and ( profiles.data->>'status' = 'pendiente'
        or (profiles.data->>'status' = 'aprobado' and profiles.data->>'role' in ('charro','equipo','dueno','ganadero'))
        or (profiles.data->>'status' = 'aprobado' and public.invite_ok(profiles.data->>'invite', profiles.data->>'role'))));

-- Pago SIMULADO: activa Pro 30 días. Para cobrar de verdad, reemplaza esta función por la confirmación del procesador de pagos.
create or replace function public.activate_pro() returns bigint
language plpgsql security definer set search_path = public as $$
declare until_ms bigint; cur bigint;
begin
  if auth.uid() is null then raise exception 'Inicia sesión para activar Pro'; end if;
  select coalesce((data->>'proUntil')::bigint, 0) into cur from profiles where id = auth.uid()::text;
  until_ms := greatest(cur, (extract(epoch from now()) * 1000)::bigint) + 30::bigint * 86400000;
  update profiles set data = data || jsonb_build_object('subscriptionStatus', 'pro', 'proUntil', until_ms, 'proRef', 'SIMULADO') where id = auth.uid()::text;
  return until_ms;
end $$;
revoke all on function public.activate_pro() from public, anon;
grant execute on function public.activate_pro() to authenticated;

-- 3) PEDIDOS DE KIT: el dueño los crea; los datos de envío solo los ven él y el súper usuario (política "requests lectura")
drop policy if exists "requests alta" on public.requests;
create policy "requests alta" on public.requests for insert with check (
  requests.data->>'createdBy' = auth.uid()::text and requests.data->>'status' = 'pendiente'
  and ( ( requests.data->>'type' = 'roster'
          and exists (select 1 from charros c where c.id = requests.data->>'charroId' and c.data->>'userId' = auth.uid()::text)
          and exists (select 1 from teams t where t.id = requests.data->>'teamId')
          and not exists (select 1 from requests r where r.data->>'type' = 'roster' and r.data->>'status' = 'pendiente'
                          and r.data->>'charroId' = requests.data->>'charroId') )
     or ( requests.data->>'type' = 'afiliacion'
          and exists (select 1 from teams t where t.id = requests.data->>'teamId' and t.data->>'captainId' = auth.uid()::text)
          and exists (select 1 from lienzos l where l.id = requests.data->>'lienzoId' and l.data->>'status' = 'aprobado')
          and not exists (select 1 from requests r where r.data->>'type' = 'afiliacion' and r.data->>'status' = 'pendiente'
                          and r.data->>'teamId' = requests.data->>'teamId') )
     or ( requests.data->>'type' = 'transfer'
          and exists (select 1 from horses h where h.id = requests.data->>'horseId' and h.data->>'ownerId' = auth.uid()::text)
          and length(coalesce(requests.data->>'code', '')) >= 8
          and not exists (select 1 from requests r where r.data->>'type' = 'transfer' and r.data->>'status' = 'pendiente'
                          and r.data->>'horseId' = requests.data->>'horseId') )
     or ( requests.data->>'type' = 'interes'
          and exists (select 1 from horses h where h.id = requests.data->>'horseId' and h.data->>'forSale' = 'true'
                      and h.data->>'ownerId' is distinct from auth.uid()::text) )
     or ( requests.data->>'type' = 'chip_order'
          and ( (requests.data->>'targetKind' = 'horse' and exists (select 1 from horses h where h.id = requests.data->>'targetId' and h.data->>'ownerId' = auth.uid()::text))
             or (requests.data->>'targetKind' = 'stock' and exists (select 1 from stock s where s.id = requests.data->>'targetId' and s.data->>'ownerId' = auth.uid()::text)) )
          and coalesce(requests.data->>'kitUid', '') = '' ) ));

-- El súper usuario actualiza pedidos (enviado, UID del chip, guía de paquetería, entregado)
drop policy if exists "requests admin" on public.requests;
create policy "requests admin" on public.requests for update using (public.is_super()) with check (public.is_super());

-- 4) MICROCHIP Y CARNET: los campos del chip solo cambian con register_chip() / validate_chip()
create or replace function public.chip_of(d jsonb) returns jsonb
language sql immutable as $$
  select jsonb_build_object('chipUid', d->'chipUid', 'chipStatus', d->'chipStatus', 'chipAt', d->'chipAt', 'chipValidatedBy', d->'chipValidatedBy')
$$;

drop policy if exists "horses alta" on public.horses;
create policy "horses alta" on public.horses for insert with check (
  public.is_approved() and horses.data->>'ownerId' = auth.uid()::text
  and jsonb_array_length(coalesce(horses.data->'history', '[]'::jsonb)) = 0
  and coalesce(horses.data->'priceOverride', 'null'::jsonb) = 'null'::jsonb
  and horses.data->'verif' is null and horses.data->'verifKey' is null and horses.data->'chipUid' is null);
drop policy if exists "horses cambio" on public.horses;
create policy "horses cambio" on public.horses for update
  using (public.is_super() or horses.data->>'ownerId' = auth.uid()::text)
  with check (public.is_super() or (
    horses.data->>'ownerId' = auth.uid()::text
    and coalesce(horses.data->'history', '[]'::jsonb) = coalesce((select h.data->'history' from horses h where h.id = horses.id), '[]'::jsonb)
    and coalesce(horses.data->'priceOverride', 'null'::jsonb) = coalesce((select h.data->'priceOverride' from horses h where h.id = horses.id), 'null'::jsonb)
    and public.verif_of(horses.data) = public.verif_of((select h.data from horses h where h.id = horses.id))
    and public.chip_of(horses.data) = public.chip_of((select h.data from horses h where h.id = horses.id))));

drop policy if exists "stock alta" on public.stock;
create policy "stock alta" on public.stock for insert with check (
  stock.data->>'ownerId' = auth.uid()::text
  and exists (select 1 from ranches r where r.id = stock.data->>'ranchId' and r.data->>'ownerId' = auth.uid()::text)
  and stock.data->'verif' is null and stock.data->'verifKey' is null and stock.data->'chipUid' is null);
drop policy if exists "stock cambio" on public.stock;
create policy "stock cambio" on public.stock for update
  using (public.is_super() or stock.data->>'ownerId' = auth.uid()::text)
  with check (public.is_super() or (stock.data->>'ownerId' = auth.uid()::text
    and exists (select 1 from ranches r where r.id = stock.data->>'ranchId' and r.data->>'ownerId' = auth.uid()::text)
    and public.verif_of(stock.data) = public.verif_of((select s.data from stock s where s.id = stock.id))
    and public.chip_of(stock.data) = public.chip_of((select s.data from stock s where s.id = stock.id))));

-- Registrar el UID del chip: el dueño del ejemplar. Si el UID coincide con el chip de un kit que se le envió, queda validado;
-- si no, queda pendiente de que el súper usuario lo valide. Un UID no se puede repetir en dos ejemplares.
create or replace function public.register_chip(kind text, rid text, uid text) returns text
language plpgsql security definer set search_path = public as $$
declare tbl text; d jsonb; u text := upper(regexp_replace(coalesce(uid, ''), '[^0-9A-Fa-f]', '', 'g')); st text;
  now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  tbl := case kind when 'horse' then 'horses' when 'stock' then 'stock' end;
  if tbl is null then raise exception 'Tipo inválido'; end if;
  if length(u) < 8 or length(u) > 32 then raise exception 'El UID debe tener entre 8 y 32 caracteres hexadecimales'; end if;
  execute format('select data from %I where id = $1 for update', tbl) into d using rid;
  if d is null then raise exception 'Ejemplar no encontrado'; end if;
  if d->>'ownerId' is distinct from auth.uid()::text then raise exception 'Solo el dueño registra el chip'; end if;
  if coalesce(d->>'chipStatus', '') = 'validado' then raise exception 'Este ejemplar ya tiene un chip validado'; end if;
  if exists (select 1 from horses where data->>'chipUid' = u and id <> rid) or exists (select 1 from stock where data->>'chipUid' = u and id <> rid) then
    raise exception 'Ese chip ya está registrado en otro ejemplar'; end if;
  st := case when exists (select 1 from requests r where r.data->>'type' = 'chip_order' and r.data->>'createdBy' = auth.uid()::text
                          and upper(regexp_replace(coalesce(r.data->>'kitUid', ''), '[^0-9A-Fa-f]', '', 'g')) = u
                          and r.data->>'status' in ('enviado', 'entregado')) then 'validado' else 'pendiente' end;
  execute format('update %I set data = data || $1 where id = $2', tbl) using jsonb_build_object(
    'chipUid', u, 'chipStatus', st, 'chipAt', now_ms, 'chipValidatedBy', case when st = 'validado' then 'kit' else null end), rid;
  return st;
end $$;
revoke all on function public.register_chip(text, text, text) from public, anon;
grant execute on function public.register_chip(text, text, text) to authenticated;

create or replace function public.validate_chip(kind text, rid text, ok boolean) returns void
language plpgsql security definer set search_path = public as $$
declare tbl text; me jsonb := public.my_data();
begin
  if not public.is_super() then raise exception 'Solo el súper usuario valida chips'; end if;
  tbl := case kind when 'horse' then 'horses' when 'stock' then 'stock' end;
  if tbl is null then raise exception 'Tipo inválido'; end if;
  execute format('update %I set data = data || $1 where id = $2', tbl) using jsonb_build_object(
    'chipStatus', case when ok then 'validado' else 'rechazado' end, 'chipValidatedBy', coalesce(me->>'name', 'Súper usuario'),
    'chipAt', (extract(epoch from now()) * 1000)::bigint), rid;
end $$;
revoke all on function public.validate_chip(text, text, boolean) from public, anon;
grant execute on function public.validate_chip(text, text, boolean) to authenticated;
