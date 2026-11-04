-- =====================================================================
-- CHARRERÍA PRO — Actualización: base limpia de CharreríaTCG
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run. Se puede correr varias veces.
-- =====================================================================

-- Catálogo público de cartas. Nadie lo escribe a mano: lo mantienen los disparadores de abajo.
-- Una carta existe si su dueño tiene Pro vigente y autorización, y si el registro está verificado.
create table if not exists public.tcg_cards (id text primary key, data jsonb not null, created_at timestamptz default now());
alter table public.tcg_cards enable row level security;
drop policy if exists "tcg_cards lectura" on public.tcg_cards;
create policy "tcg_cards lectura" on public.tcg_cards for select using (true);
grant select on public.tcg_cards to anon, authenticated;   -- solo lectura: Supabase ya no da acceso automático a las tablas nuevas

-- Debe coincidir con tcgSyncLocal() de la app
create or replace function public.tcg_sync(kind text, rid text) returns void
language plpgsql security definer set search_path = public as $$
declare tbl text; d jsonb; p jsonb; owner_id text; now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  tbl := case kind when 'charro' then 'charros' when 'horse' then 'horses' when 'stock' then 'stock' end;
  if tbl is null then return; end if;
  execute format('select data from %I where id = $1', tbl) into d using rid;
  owner_id := case when kind = 'charro' then d->>'userId' else d->>'ownerId' end;
  if owner_id is not null then select data into p from profiles where id = owner_id; end if;
  if d is not null and p is not null and p->'tcgConsent' is not null and jsonb_typeof(p->'tcgConsent') = 'object'
     and p->>'subscriptionStatus' = 'pro' and coalesce((p->>'proUntil')::bigint, 0) > now_ms
     and d->>'verif' = 'oficial' and d->>'verifKey' = public.verif_key(kind, d)
     and (kind <> 'stock' or d->>'mode' = 'unidad') then
    insert into tcg_cards (id, data) values (kind || '-' || rid, jsonb_build_object('id', kind || '-' || rid, 'kind', kind, 'refId', rid,
      'name', d->>'name', 'ownerId', owner_id, 'activeUntil', (p->>'proUntil')::bigint, 'updatedAt', now_ms))
    on conflict (id) do update set data = excluded.data;
  else
    delete from tcg_cards where id = kind || '-' || rid;
  end if;
end $$;
revoke all on function public.tcg_sync(text, text) from public, anon, authenticated;

create or replace function public.trg_tcg_source() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.tcg_sync(tg_argv[0], coalesce(new.id, old.id));
  return null;
end $$;

create or replace function public.trg_tcg_profile() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select 'charro' k, id from charros where data->>'userId' = new.id
     union all select 'horse', id from horses where data->>'ownerId' = new.id
     union all select 'stock', id from stock where data->>'ownerId' = new.id loop
    perform public.tcg_sync(r.k, r.id);
  end loop;
  return null;
end $$;

drop trigger if exists trg_tcg_charros on public.charros;
create trigger trg_tcg_charros after insert or update or delete on public.charros for each row execute function public.trg_tcg_source('charro');
drop trigger if exists trg_tcg_horses on public.horses;
create trigger trg_tcg_horses after insert or update or delete on public.horses for each row execute function public.trg_tcg_source('horse');
drop trigger if exists trg_tcg_stock on public.stock;
create trigger trg_tcg_stock after insert or update or delete on public.stock for each row execute function public.trg_tcg_source('stock');
drop trigger if exists trg_tcg_profiles on public.profiles;
create trigger trg_tcg_profiles after insert or update on public.profiles for each row execute function public.trg_tcg_profile();

-- Avisa a la app en tiempo real
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'tcg_cards') then
    alter publication supabase_realtime add table public.tcg_cards;
  end if;
end $$;

-- Llena el catálogo con lo que ya existe
do $$ declare r record; begin
  for r in select 'charro' k, id from charros union all select 'horse', id from horses union all select 'stock', id from stock loop
    perform public.tcg_sync(r.k, r.id);
  end loop;
end $$;

-- Recarga las tablas de la API y confirma: debe mostrar tcg_cards
notify pgrst, 'reload schema';
select to_regclass('public.tcg_cards') as tabla, (select count(*) from public.tcg_cards) as cartas;
