-- =====================================================================
-- CHARRERÍA PRO — Actualización: equipo del lienzo y bitácora por lienzo
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run. Se puede correr varias veces.
-- =====================================================================

-- Un lienzo lo administran su responsable y hasta 3 personas más (lienzos.data.admins).
create or replace function public.owns_lienzo(lid text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_approved() and exists (
    select 1 from lienzos l
    where l.id = lid and l.data->>'status' = 'aprobado'
      and (l.data->>'ownerId' = auth.uid()::text or coalesce(l.data->'admins', '[]'::jsonb) ? auth.uid()::text))
$$;

-- El dueño original es el único que usa esta política: sin esa condición, un integrante podría ponerse como dueño.
drop policy if exists "lienzos cambio" on public.lienzos;
create policy "lienzos cambio" on public.lienzos for update
  using (public.is_super() or lienzos.data->>'ownerId' = auth.uid()::text)
  with check (public.is_super() or (
    lienzos.data->>'ownerId' = auth.uid()::text
    and (select l.data->>'ownerId' from lienzos l where l.id = lienzos.id) = auth.uid()::text
    and lienzos.data->>'status' = (select l.data->>'status' from lienzos l where l.id = lienzos.id)
    and coalesce(lienzos.data->'admins', '[]'::jsonb) = coalesce((select l.data->'admins' from lienzos l where l.id = lienzos.id), '[]'::jsonb)
    and coalesce(lienzos.data->'pendientes', '[]'::jsonb) = coalesce((select l.data->'pendientes' from lienzos l where l.id = lienzos.id), '[]'::jsonb)));

-- Los integrantes editan el lienzo, pero no cambian su estado, su responsable ni su equipo.
drop policy if exists "lienzos equipo" on public.lienzos;
create policy "lienzos equipo" on public.lienzos for update
  using (coalesce(lienzos.data->'admins', '[]'::jsonb) ? auth.uid()::text)
  with check (coalesce(lienzos.data->'admins', '[]'::jsonb) ? auth.uid()::text
    and lienzos.data->>'status' = (select l.data->>'status' from lienzos l where l.id = lienzos.id)
    and lienzos.data->>'ownerId' = (select l.data->>'ownerId' from lienzos l where l.id = lienzos.id)
    and lienzos.data->'admins' = (select l.data->'admins' from lienzos l where l.id = lienzos.id)
    and coalesce(lienzos.data->'pendientes', '[]'::jsonb) = coalesce((select l.data->'pendientes' from lienzos l where l.id = lienzos.id), '[]'::jsonb));

-- El responsable propone a un integrante y solo el súper usuario le abre el panel. El correo se busca aquí: no se expone a la app.
create or replace function public.lienzo_agregar(lid text, correo text) returns text
language plpgsql security definer set search_path = public as $$
declare l jsonb; pid text; nombre text; a jsonb; q jsonb;
begin
  select data into l from lienzos where id = lid;
  if l is null or not (public.is_super() or l->>'ownerId' = auth.uid()::text) then raise exception 'Solo el responsable del lienzo puede hacerlo'; end if;
  select id, data->>'name' into pid, nombre from profiles where lower(data->>'email') = lower(trim(correo)) limit 1;
  if pid is null then raise exception 'Esa persona primero debe crear su cuenta'; end if;
  a := coalesce(l->'admins', '[]'::jsonb); q := coalesce(l->'pendientes', '[]'::jsonb);
  if pid = l->>'ownerId' or a ? pid or q ? pid then raise exception 'Ya es parte del lienzo'; end if;
  if jsonb_array_length(a) + jsonb_array_length(q) >= 3 then raise exception 'Máximo 4 personas por lienzo'; end if;
  update lienzos set data = data || jsonb_build_object('pendientes', q || to_jsonb(pid),
    'adminNames', coalesce(data->'adminNames', '{}'::jsonb) || jsonb_build_object(pid, nombre)) where id = lid;
  return nombre;
end $$;

create or replace function public.lienzo_decidir(lid text, pid text, ok boolean) returns void
language plpgsql security definer set search_path = public as $$
declare l jsonb;
begin
  if not public.is_super() then raise exception 'Solo el súper usuario autoriza'; end if;
  select data into l from lienzos where id = lid;
  if l is null or not coalesce(l->'pendientes', '[]'::jsonb) ? pid then raise exception 'No hay solicitud pendiente'; end if;
  update lienzos set data = data || jsonb_build_object('pendientes', (data->'pendientes') - pid,
    'admins', case when ok then coalesce(data->'admins', '[]'::jsonb) || to_jsonb(pid) else coalesce(data->'admins', '[]'::jsonb) end,
    'adminNames', case when ok then coalesce(data->'adminNames', '{}'::jsonb) else coalesce(data->'adminNames', '{}'::jsonb) - pid end) where id = lid;
end $$;

create or replace function public.lienzo_quitar(lid text, pid text) returns void
language plpgsql security definer set search_path = public as $$
declare l jsonb;
begin
  select data into l from lienzos where id = lid;
  if l is null or not (public.is_super() or l->>'ownerId' = auth.uid()::text) then raise exception 'Solo el responsable del lienzo puede hacerlo'; end if;
  update lienzos set data = data || jsonb_build_object('admins', coalesce(data->'admins', '[]'::jsonb) - pid,
    'pendientes', coalesce(data->'pendientes', '[]'::jsonb) - pid, 'adminNames', coalesce(data->'adminNames', '{}'::jsonb) - pid) where id = lid;
end $$;
revoke all on function public.lienzo_agregar(text, text) from public, anon;
revoke all on function public.lienzo_quitar(text, text) from public, anon;
revoke all on function public.lienzo_decidir(text, text, boolean) from public, anon;
grant execute on function public.lienzo_decidir(text, text, boolean) to authenticated;
grant execute on function public.lienzo_agregar(text, text) to authenticated;
grant execute on function public.lienzo_quitar(text, text) to authenticated;

-- Una cuenta es charro o escaramuza, no ambos: tiene un solo perfil de competidor.
create or replace function public.tiene_charro(uid text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from charros c where c.data->>'userId' = uid)
$$;
revoke all on function public.tiene_charro(text) from public, anon;
grant execute on function public.tiene_charro(text) to authenticated;
drop policy if exists "charros alta" on public.charros;
create policy "charros alta" on public.charros for insert with check (
  public.is_super() or (charros.data->>'userId' = auth.uid()::text and coalesce(charros.data->>'teamId','') = ''
    and charros.data->'verif' is null and charros.data->'verifKey' is null
    and not public.tiene_charro(auth.uid()::text)));

-- Cada lienzo ve quién hizo qué en su lienzo.
drop policy if exists "audit lienzo" on public.audit;
create policy "audit lienzo" on public.audit for select using (public.owns_lienzo(audit.data->>'lienzoId'));
