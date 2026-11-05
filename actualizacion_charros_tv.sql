-- =====================================================================
-- CHARRERÍA PRO — Actualización: solicitudes del kit de cámaras y de Charros TV
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run. Se puede correr varias veces.
-- =====================================================================

-- Se suma a "requests alta". Cada persona tiene máximo una solicitud pendiente de cada tipo.
-- Una política que consulta su propia tabla falla con 42P17: por eso usa req_pending(), que es security definer.
drop policy if exists "requests charros tv" on public.requests;
create policy "requests charros tv" on public.requests for insert with check (
  requests.data->>'createdBy' = auth.uid()::text
  and requests.data->>'status' = 'pendiente'
  and requests.data->>'type' in ('tv_kit', 'tv_sub')
  and not exists (select 1 where public.req_pending(requests.data->>'type', 'createdBy', auth.uid()::text))
);
