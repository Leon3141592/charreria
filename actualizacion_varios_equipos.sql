-- =====================================================================
-- CHARRERÍA PRO — Actualización: un charro en varios equipos
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run y confirma con "Run query".
-- La advertencia aparece porque reemplaza un permiso; no borra datos. Se puede correr varias veces.
-- =====================================================================

-- teamId es el equipo que el charro muestra al público; teamIds son todos sus equipos oficiales.
create or replace function public.equipos_charro(d jsonb) returns jsonb
language sql immutable as $$
  select case when jsonb_typeof(d->'teamIds') = 'array' and jsonb_array_length(d->'teamIds') > 0 then d->'teamIds'
              when coalesce(d->>'teamId', '') <> '' then jsonb_build_array(d->>'teamId')
              else '[]'::jsonb end
$$;

create or replace function public.decide_request(rid text, decision text) returns void
language plpgsql security definer set search_path = public as $$
declare r jsonb; me jsonb := public.my_data(); uid text := auth.uid()::text;
begin
  select data into r from requests where id = rid for update;
  if r is null then raise exception 'Solicitud no encontrada'; end if;
  if r->>'status' <> 'pendiente' then raise exception 'Esta solicitud ya fue resuelta'; end if;
  if decision = 'cancelado' then
    if r->>'createdBy' is distinct from uid then raise exception 'No tienes permiso para esta acción'; end if;
  elsif decision in ('aprobado','rechazado') then
    if r->>'type' = 'afiliacion' then
      if not (public.is_super() or public.owns_lienzo(r->>'lienzoId')) then raise exception 'No tienes permiso para esta acción'; end if;
    elsif r->>'type' = 'roster' then
      if not public.can_decide_team(r->>'teamId') then raise exception 'No tienes permiso para esta acción'; end if;
    elsif r->>'type' = 'interes' then
      if not exists (select 1 from horses h where h.id = r->>'horseId' and h.data->>'ownerId' = uid) then raise exception 'No tienes permiso para esta acción'; end if;
    else raise exception 'No tienes permiso para esta acción'; end if;
  else raise exception 'Decisión inválida'; end if;

  update requests set data = data || jsonb_build_object('status', decision, 'decidedBy', uid,
    'decidedByName', coalesce(me->>'name', ''), 'decidedAt', (extract(epoch from now()) * 1000)::bigint) where id = rid;
  if decision = 'aprobado' and r->>'type' = 'roster' then
    -- El primer equipo es el público; los siguientes se suman sin reemplazarlo.
    update charros set data = data || jsonb_build_object(
      'teamId', coalesce(nullif(data->>'teamId', ''), r->>'teamId'),
      'teamIds', public.equipos_charro(data) || (case when public.equipos_charro(data) ? (r->>'teamId') then '[]'::jsonb else to_jsonb(r->>'teamId') end))
    where id = r->>'charroId';
  elsif decision = 'aprobado' and r->>'type' = 'afiliacion' then
    update teams set data = data || jsonb_build_object('lienzoId', r->>'lienzoId', 'lienzoStatus', 'aprobado') where id = r->>'teamId';
  end if;
end $$;

-- Sale de un equipo sin perder los demás. Si era el público, muestra el siguiente.
create or replace function public.charro_salir(cid text, tid text) returns void
language plpgsql security definer set search_path = public as $$
declare c jsonb; q jsonb;
begin
  select data into c from charros where id = cid for update;
  if c is null then raise exception 'Charro no encontrado'; end if;
  if not (c->>'userId' = auth.uid()::text or public.can_decide_team(tid)) then raise exception 'No tienes permiso para esta acción'; end if;
  q := public.equipos_charro(c) - tid;
  update charros set data = data || jsonb_build_object('teamIds', q,
    'teamId', case when c->>'teamId' = tid then q->>0 else c->>'teamId' end) where id = cid;
end $$;

-- El charro elige cuál de sus equipos ve el público. Solo puede elegir uno al que ya pertenece.
create or replace function public.charro_equipo_publico(cid text, tid text) returns void
language plpgsql security definer set search_path = public as $$
declare c jsonb;
begin
  select data into c from charros where id = cid for update;
  if c is null or c->>'userId' is distinct from auth.uid()::text then raise exception 'No tienes permiso para esta acción'; end if;
  if not public.equipos_charro(c) ? tid then raise exception 'No perteneces a ese equipo'; end if;
  update charros set data = data || jsonb_build_object('teamId', tid) where id = cid;
end $$;
revoke all on function public.charro_salir(text, text) from public, anon;
revoke all on function public.charro_equipo_publico(text, text) from public, anon;
grant execute on function public.charro_salir(text, text) to authenticated;
grant execute on function public.charro_equipo_publico(text, text) to authenticated;

-- El charro edita su perfil, pero no se agrega equipos por su cuenta.
drop policy if exists "charros cambio" on public.charros;
create policy "charros cambio" on public.charros for update
  using (public.is_super() or charros.data->>'userId' = auth.uid()::text)
  with check (public.is_super() or (
    charros.data->>'userId' = auth.uid()::text
    and coalesce(charros.data->>'teamId','') = coalesce((select c.data->>'teamId' from charros c where c.id = charros.id),'')
    and coalesce(charros.data->'teamIds','[]'::jsonb) = coalesce((select c.data->'teamIds' from charros c where c.id = charros.id),'[]'::jsonb)
    and public.verif_of(charros.data) = public.verif_of((select c.data from charros c where c.id = charros.id))));

notify pgrst, 'reload schema';

-- Debe mostrar 3 filas.
select proname as instalado from pg_proc where proname in ('equipos_charro','charro_salir','charro_equipo_publico') order by 1;
