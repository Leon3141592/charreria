-- =====================================================================
-- CHARRERÍA PRO — Actualización: cuenta de público
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run. Se puede correr varias veces.
-- =====================================================================

-- Se suma a "profiles alta": el público se registra activo, sin verificación ni Pro.
drop policy if exists "profiles publico" on public.profiles;
create policy "profiles publico" on public.profiles for insert with check (
  id = auth.uid()::text
  and profiles.data->>'role' = 'publico'
  and profiles.data->>'status' = 'aprobado'
  and coalesce(profiles.data->>'verified', 'false') = 'false'
  and coalesce(profiles.data->>'subscriptionStatus', 'free') = 'free'
);
