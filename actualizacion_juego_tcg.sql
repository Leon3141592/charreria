-- =====================================================================
-- CHARRERÍA PRO — Actualización: juego de CharreríaTCG
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run y confirma con "Run query".
-- La advertencia aparece porque reemplaza permisos; no borra datos. Se puede correr varias veces.
-- Las cartas, los premios y las partidas en línea se deciden aquí para que nadie los altere desde el navegador.
-- =====================================================================

create table if not exists public.tcg_catalogo (id text primary key, data jsonb not null);
create table if not exists public.tcg_mis_cartas (id text primary key, data jsonb not null, created_at timestamptz default now());
create table if not exists public.tcg_jugadores (id text primary key, data jsonb not null, created_at timestamptz default now());
create table if not exists public.tcg_partidas (id text primary key, data jsonb not null, created_at timestamptz default now());
create table if not exists public.tcg_jugadas (partida text not null, jugador text not null, c text not null, h text, primary key (partida, jugador));
create table if not exists public.tcg_codigos (id text primary key, data jsonb not null, created_at timestamptz default now());
alter table public.tcg_catalogo enable row level security;
alter table public.tcg_mis_cartas enable row level security;
alter table public.tcg_jugadores enable row level security;
alter table public.tcg_partidas enable row level security;
alter table public.tcg_jugadas enable row level security;   -- sin políticas: nadie lee la jugada secreta del rival
alter table public.tcg_codigos enable row level security;

insert into public.tcg_catalogo (id, data) values
('c01','{"id": "c01", "tipo": "charro", "nombre": "Pancho Novato", "tier": "basica", "reata": 3, "rienda": 3, "jineteo": 2}'::jsonb),
('c02','{"id": "c02", "tipo": "charro", "nombre": "Lupe Aprendiz", "tier": "basica", "reata": 3, "rienda": 2, "jineteo": 3}'::jsonb),
('c03','{"id": "c03", "tipo": "charro", "nombre": "Toñito Rancho", "tier": "basica", "reata": 2, "rienda": 3, "jineteo": 3}'::jsonb),
('c04','{"id": "c04", "tipo": "charro", "nombre": "Beto Corral", "tier": "basica", "reata": 4, "rienda": 2, "jineteo": 2}'::jsonb),
('c05','{"id": "c05", "tipo": "charro", "nombre": "Ramón Potrero", "tier": "basica", "reata": 2, "rienda": 4, "jineteo": 2}'::jsonb),
('c06','{"id": "c06", "tipo": "charro", "nombre": "Goyito Silla", "tier": "basica", "reata": 2, "rienda": 2, "jineteo": 4}'::jsonb),
('c07','{"id": "c07", "tipo": "charro", "nombre": "Chente Campo", "tier": "basica", "reata": 3, "rienda": 3, "jineteo": 3}'::jsonb),
('c08','{"id": "c08", "tipo": "charro", "nombre": "Nacho Lazada", "tier": "basica", "reata": 4, "rienda": 3, "jineteo": 1}'::jsonb),
('c09','{"id": "c09", "tipo": "charro", "nombre": "Memín Soga", "tier": "basica", "reata": 3, "rienda": 4, "jineteo": 1}'::jsonb),
('c10','{"id": "c10", "tipo": "charro", "nombre": "Julián Cerca", "tier": "basica", "reata": 1, "rienda": 3, "jineteo": 4}'::jsonb),
('c11','{"id": "c11", "tipo": "charro", "nombre": "Rafa Establo", "tier": "basica", "reata": 3, "rienda": 2, "jineteo": 3}'::jsonb),
('c12','{"id": "c12", "tipo": "charro", "nombre": "Tacho Pastura", "tier": "basica", "reata": 2, "rienda": 3, "jineteo": 3}'::jsonb),
('c13','{"id": "c13", "tipo": "charro", "nombre": "Chuy Lazadas", "tier": "bronce", "reata": 6, "rienda": 4, "jineteo": 2}'::jsonb),
('c14','{"id": "c14", "tipo": "charro", "nombre": "Toño Rienditas", "tier": "bronce", "reata": 3, "rienda": 6, "jineteo": 3}'::jsonb),
('c15','{"id": "c15", "tipo": "charro", "nombre": "Memo Aguante", "tier": "bronce", "reata": 2, "rienda": 4, "jineteo": 6}'::jsonb),
('c16','{"id": "c16", "tipo": "charro", "nombre": "Paco Pialín", "tier": "bronce", "reata": 6, "rienda": 3, "jineteo": 3}'::jsonb),
('c17','{"id": "c17", "tipo": "charro", "nombre": "Lalo Galope", "tier": "bronce", "reata": 4, "rienda": 6, "jineteo": 2}'::jsonb),
('c18','{"id": "c18", "tipo": "charro", "nombre": "Rudy Montado", "tier": "bronce", "reata": 3, "rienda": 3, "jineteo": 6}'::jsonb),
('c19','{"id": "c19", "tipo": "charro", "nombre": "Nico Soguilla", "tier": "bronce", "reata": 5, "rienda": 4, "jineteo": 3}'::jsonb),
('c20','{"id": "c20", "tipo": "charro", "nombre": "Beto Estribo", "tier": "bronce", "reata": 4, "rienda": 5, "jineteo": 3}'::jsonb),
('c21','{"id": "c21", "tipo": "charro", "nombre": "Quique Brinco", "tier": "bronce", "reata": 4, "rienda": 3, "jineteo": 5}'::jsonb),
('c22','{"id": "c22", "tipo": "charro", "nombre": "Tavo Parejo", "tier": "bronce", "reata": 4, "rienda": 4, "jineteo": 4}'::jsonb),
('c23','{"id": "c23", "tipo": "charro", "nombre": "Lencho Reatazo", "tier": "plata", "reata": 8, "rienda": 4, "jineteo": 3}'::jsonb),
('c24','{"id": "c24", "tipo": "charro", "nombre": "Chema Espuela", "tier": "plata", "reata": 4, "rienda": 8, "jineteo": 3}'::jsonb),
('c25','{"id": "c25", "tipo": "charro", "nombre": "Goyo Bronco", "tier": "plata", "reata": 3, "rienda": 4, "jineteo": 8}'::jsonb),
('c26','{"id": "c26", "tipo": "charro", "nombre": "Santi Floreo", "tier": "plata", "reata": 7, "rienda": 5, "jineteo": 3}'::jsonb),
('c27','{"id": "c27", "tipo": "charro", "nombre": "Mateo Freno", "tier": "plata", "reata": 5, "rienda": 7, "jineteo": 3}'::jsonb),
('c28','{"id": "c28", "tipo": "charro", "nombre": "Ramiro Toretes", "tier": "plata", "reata": 3, "rienda": 5, "jineteo": 7}'::jsonb),
('c29','{"id": "c29", "tipo": "charro", "nombre": "Fermín Cabal", "tier": "plata", "reata": 5, "rienda": 5, "jineteo": 5}'::jsonb),
('c30','{"id": "c30", "tipo": "charro", "nombre": "Nacho Ligero", "tier": "plata", "reata": 6, "rienda": 6, "jineteo": 3}'::jsonb),
('c31','{"id": "c31", "tipo": "charro", "nombre": "El Zurdo de la Loma", "tier": "oro", "reata": 9, "rienda": 5, "jineteo": 4}'::jsonb),
('c32','{"id": "c32", "tipo": "charro", "nombre": "Don Crispín", "tier": "oro", "reata": 5, "rienda": 9, "jineteo": 4}'::jsonb),
('c33','{"id": "c33", "tipo": "charro", "nombre": "Tiburcio Trueno", "tier": "oro", "reata": 4, "rienda": 5, "jineteo": 9}'::jsonb),
('c34','{"id": "c34", "tipo": "charro", "nombre": "El Güero Sogas", "tier": "oro", "reata": 8, "rienda": 6, "jineteo": 4}'::jsonb),
('c35','{"id": "c35", "tipo": "charro", "nombre": "Rosendo Valiente", "tier": "oro", "reata": 6, "rienda": 6, "jineteo": 6}'::jsonb),
('c36','{"id": "c36", "tipo": "charro", "nombre": "Don Maximino", "tier": "oro", "reata": 8, "rienda": 7, "jineteo": 6}'::jsonb),
('h01','{"id": "h01", "tipo": "caballo", "nombre": "Prieto", "tier": "basica", "rienda": 1, "reata": 0, "jineteo": 0}'::jsonb),
('h02','{"id": "h02", "tipo": "caballo", "nombre": "Pinto", "tier": "basica", "rienda": 0, "reata": 1, "jineteo": 0}'::jsonb),
('h03','{"id": "h03", "tipo": "caballo", "nombre": "Tostado", "tier": "basica", "rienda": 1, "reata": 0, "jineteo": 0}'::jsonb),
('h04','{"id": "h04", "tipo": "caballo", "nombre": "Rucio", "tier": "basica", "rienda": 0, "reata": 1, "jineteo": 0}'::jsonb),
('h05','{"id": "h05", "tipo": "caballo", "nombre": "Canelita", "tier": "basica", "rienda": 1, "reata": 1, "jineteo": 0}'::jsonb),
('h06','{"id": "h06", "tipo": "caballo", "nombre": "Bayito", "tier": "basica", "rienda": 1, "reata": 0, "jineteo": 0}'::jsonb),
('h07','{"id": "h07", "tipo": "caballo", "nombre": "Canelo Viejo", "tier": "bronce", "rienda": 1, "reata": 1, "jineteo": 0}'::jsonb),
('h08','{"id": "h08", "tipo": "caballo", "nombre": "Tordillo", "tier": "bronce", "rienda": 2, "reata": 0, "jineteo": 0}'::jsonb),
('h09','{"id": "h09", "tipo": "caballo", "nombre": "Pinolillo", "tier": "bronce", "rienda": 0, "reata": 2, "jineteo": 0}'::jsonb),
('h10','{"id": "h10", "tipo": "caballo", "nombre": "Sombra", "tier": "bronce", "rienda": 1, "reata": 1, "jineteo": 0}'::jsonb),
('h11','{"id": "h11", "tipo": "caballo", "nombre": "Relámpago Bayo", "tier": "plata", "rienda": 3, "reata": 0, "jineteo": 0}'::jsonb),
('h12','{"id": "h12", "tipo": "caballo", "nombre": "Cuerdas", "tier": "plata", "rienda": 0, "reata": 3, "jineteo": 0}'::jsonb),
('h13','{"id": "h13", "tipo": "caballo", "nombre": "Mezquite", "tier": "plata", "rienda": 2, "reata": 1, "jineteo": 0}'::jsonb),
('h14','{"id": "h14", "tipo": "caballo", "nombre": "Alba", "tier": "plata", "rienda": 1, "reata": 2, "jineteo": 0}'::jsonb),
('h15','{"id": "h15", "tipo": "caballo", "nombre": "Rey de Copas", "tier": "oro", "rienda": 3, "reata": 1, "jineteo": 0}'::jsonb),
('h16','{"id": "h16", "tipo": "caballo", "nombre": "Tempestad", "tier": "oro", "rienda": 1, "reata": 3, "jineteo": 0}'::jsonb)
on conflict (id) do update set data = excluded.data;

insert into public.settings (id, data) values ('tcg_banco', '{"id":"tcg_banco","plata":100,"oro":50}'::jsonb) on conflict (id) do nothing;

drop policy if exists "tcg catalogo lectura" on public.tcg_catalogo;
create policy "tcg catalogo lectura" on public.tcg_catalogo for select using (true);
drop policy if exists "tcg jugadores lectura" on public.tcg_jugadores;
create policy "tcg jugadores lectura" on public.tcg_jugadores for select using (true);
drop policy if exists "tcg cartas lectura" on public.tcg_mis_cartas;
create policy "tcg cartas lectura" on public.tcg_mis_cartas for select using (public.is_super() or tcg_mis_cartas.data->>'ownerId' = auth.uid()::text);
drop policy if exists "tcg partidas lectura" on public.tcg_partidas;
create policy "tcg partidas lectura" on public.tcg_partidas for select using (public.is_super() or auth.uid()::text in (tcg_partidas.data->>'a', tcg_partidas.data->>'b'));
drop policy if exists "tcg codigos lectura" on public.tcg_codigos;
create policy "tcg codigos lectura" on public.tcg_codigos for select using (public.is_super());
grant select on public.tcg_catalogo, public.tcg_jugadores, public.tcg_mis_cartas, public.tcg_partidas to anon, authenticated;
grant select on public.tcg_codigos to authenticated;

create or replace function public.tcg_uid() returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.is_approved() then raise exception 'Inicia sesión para jugar'; end if;
  return auth.uid()::text;
end $$;

create or replace function public.tcg_codigo_nuevo(pre text) returns text
language sql volatile as $$ select pre || '-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8)) $$;

create or replace function public.tcg_dar(uid text, cid text, origen text) returns text
language plpgsql security definer set search_path = public as $$
declare i text := 'm' || substr(md5(random()::text || clock_timestamp()::text), 1, 14);
begin
  insert into tcg_mis_cartas (id, data) values (i, jsonb_build_object('id', i, 'ownerId', uid, 'cardId', cid, 'origen', origen, 'at', (extract(epoch from now()) * 1000)::bigint));
  return cid;
end $$;

create or replace function public.tcg_al_azar(t text) returns text
language sql volatile set search_path = public as $$ select id from tcg_catalogo where data->>'tier' = t order by random() limit 1 $$;

-- Primera vez: 8 charros y 4 caballos básicos.
create or replace function public.tcg_inicio() returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid text := public.tcg_uid(); j jsonb; r record; nom text;
begin
  select data into j from tcg_jugadores where id = uid for update;
  if j is not null then return j; end if;
  select data->>'name' into nom from profiles where id = uid;
  j := jsonb_build_object('id', uid, 'name', coalesce(nom, 'Jugador'), 'partidas', 0, 'victorias', 0, 'puntos', 0, 'dia', '', 'premiosDia', 0);
  insert into tcg_jugadores (id, data) values (uid, j);
  for r in select id from tcg_catalogo where data->>'tier' = 'basica' and data->>'tipo' = 'charro' order by random() limit 8 loop perform public.tcg_dar(uid, r.id, 'inicial'); end loop;
  for r in select id from tcg_catalogo where data->>'tier' = 'basica' and data->>'tipo' = 'caballo' order by random() limit 4 loop perform public.tcg_dar(uid, r.id, 'inicial'); end loop;
  return j;
end $$;

-- Máximo 6 cartas de regalo al día. Al ganar siempre hay carta; 15% de ser bronce. Al perder, 30% de básica.
create or replace function public.tcg_resultado(uid text, gano boolean, pts int) returns text
language plpgsql security definer set search_path = public as $$
declare j jsonb; hoy text := current_date::text; n int; cid text;
begin
  select data into j from tcg_jugadores where id = uid for update;
  if j is null then return null; end if;
  n := case when j->>'dia' = hoy then (j->>'premiosDia')::int else 0 end;
  if n < 6 and (gano or random() < .3) then
    cid := public.tcg_dar(uid, public.tcg_al_azar(case when gano and random() < .15 then 'bronce' else 'basica' end), 'regalo');
    n := n + 1;
  end if;
  update tcg_jugadores set data = data || jsonb_build_object('dia', hoy, 'premiosDia', n, 'partidas', (j->>'partidas')::int + 1,
    'victorias', (j->>'victorias')::int + gano::int, 'puntos', (j->>'puntos')::int + case when n < 6 or cid is not null then pts else 0 end) where id = uid;
  return cid;
end $$;

-- La partida contra la IA corre en el navegador: por eso sus premios tienen tope diario.
create or replace function public.tcg_premio(p_gano boolean, p_nivel int) returns text
language plpgsql security definer set search_path = public as $$
declare uid text := public.tcg_uid();
begin
  perform public.tcg_inicio();
  return public.tcg_resultado(uid, p_gano, 1 + case when p_gano then least(greatest(p_nivel, 1), 3) else 0 end);
end $$;

create or replace function public.tcg_faena(i int) returns jsonb
language sql immutable as $$
  select ('[{"stat":"rienda","caballo":true,"s":1,"b":0},{"stat":"reata","caballo":true,"s":1,"b":0},{"stat":"rienda","caballo":true,"s":1,"b":0},{"stat":"jineteo","caballo":false,"s":1,"b":6},{"stat":"reata","caballo":false,"s":1,"b":0},{"stat":"reata","caballo":true,"s":1,"b":0},{"stat":"jineteo","caballo":true,"s":3,"b":7}]'::jsonb)->i
$$;

-- Un mazo son 8 charros y 4 caballos propios, sin repetir y con costo máximo de 20.
create or replace function public.tcg_mazo_ok(uid text, m jsonb) returns void
language plpgsql stable security definer set search_path = public as $$
declare nc int; nh int; costo int; propias int;
begin
  select count(*) filter (where c.data->>'tipo' = 'charro'), count(*) filter (where c.data->>'tipo' = 'caballo'),
         coalesce(sum(case c.data->>'tier' when 'plata' then 2 when 'oro' then 3 else 1 end), 0)
    into nc, nh, costo from tcg_catalogo c where c.id in (select distinct jsonb_array_elements_text(m));
  select count(distinct x.v) into propias from jsonb_array_elements_text(m) x(v)
    where exists (select 1 from tcg_mis_cartas k where k.data->>'ownerId' = uid and k.data->>'cardId' = x.v);
  if nc <> 8 or nh <> 4 or jsonb_array_length(m) <> 12 or costo > 20 or propias <> 12 then raise exception 'Tu mazo no es válido'; end if;
end $$;

create or replace function public.tcg_crear_partida(p_modo text, p_faena int, p_mazo jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare uid text := public.tcg_uid(); i text := 'p' || substr(md5(random()::text || clock_timestamp()::text), 1, 14); cod text := public.tcg_codigo_nuevo('RETA'); nom text;
begin
  perform public.tcg_inicio();
  if p_modo not in ('charreada', 'suerte') or p_faena not between 0 and 6 then raise exception 'Modo inválido'; end if;
  perform public.tcg_mazo_ok(uid, p_mazo);
  select data->>'name' into nom from tcg_jugadores where id = uid;
  insert into tcg_partidas (id, data) values (i, jsonb_build_object('id', i, 'codigo', cod, 'modo', p_modo, 'faena', p_faena, 'a', uid, 'aNombre', nom, 'b', null, 'estado', 'esperando',
    'ronda', 0, 'mazoA', p_mazo, 'usadosA', '[]'::jsonb, 'usadosB', '[]'::jsonb, 'listoA', false, 'listoB', false, 'sa', 0, 'sb', 0, 'bote', 0, 'log', '[]'::jsonb, 'at', (extract(epoch from now()) * 1000)::bigint));
  return i;
end $$;

create or replace function public.tcg_unirse(p_codigo text, p_mazo jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare uid text := public.tcg_uid(); p record; nom text;
begin
  perform public.tcg_inicio();
  select id, data into p from tcg_partidas where data->>'codigo' = upper(trim(p_codigo)) and data->>'estado' = 'esperando' for update;
  if p.id is null then raise exception 'Código inválido o partida ya iniciada'; end if;
  if p.data->>'a' = uid then raise exception 'No puedes jugar contra ti mismo'; end if;
  perform public.tcg_mazo_ok(uid, p_mazo);
  select data->>'name' into nom from tcg_jugadores where id = uid;
  update tcg_partidas set data = data || jsonb_build_object('b', uid, 'bNombre', nom, 'mazoB', p_mazo, 'estado', 'jugando') where id = p.id;
  return p.id;
end $$;

create or replace function public.tcg_valor(cid text, hid text, f jsonb) returns int
language plpgsql stable set search_path = public as $$
declare st text := f->>'stat'; c jsonb; h jsonb; hs text;
begin
  select data into c from tcg_catalogo where id = cid;
  if hid is not null then select data into h from tcg_catalogo where id = hid; end if;
  hs := case when st = 'jineteo' then 'rienda' else st end;
  return (c->>st)::int + coalesce((h->>hs)::int, 0);
end $$;

create or replace function public.tcg_jugar(p_id text, p_c text, p_h text) returns void
language plpgsql security definer set search_path = public as $$
declare uid text := public.tcg_uid(); p jsonb; lado text; f jsonb; ja record; jb record; ta int; tb int; oa boolean; ob boolean; s int; bote int; w text; sa int; sb int; ronda int; total int; suertes int[] := array[-2,-2,-2,0,0,0,1,1,1,2,2,2,4,4,4,6]; ua int; ub int; ganador text;
begin
  select data into p from tcg_partidas where id = p_id for update;
  if p is null or p->>'estado' <> 'jugando' then raise exception 'La partida no está activa'; end if;
  lado := case uid when p->>'a' then 'A' when p->>'b' then 'B' else null end;
  if lado is null then raise exception 'No juegas en esta partida'; end if;
  if (p->('listo' || lado))::text = 'true' then raise exception 'Ya jugaste esta faena'; end if;
  ronda := (p->>'ronda')::int; total := case when p->>'modo' = 'suerte' then 3 else 7 end;
  f := public.tcg_faena(case when p->>'modo' = 'suerte' then (p->>'faena')::int else ronda end);
  if not (p->('mazo' || lado)) ? p_c or p->('usados' || lado) ? p_c or left(p_c, 1) <> 'c' then raise exception 'Esa carta no está disponible'; end if;
  if p_h is not null and (not (f->>'caballo')::boolean or not (p->('mazo' || lado)) ? p_h or p->('usados' || lado) ? p_h or left(p_h, 1) <> 'h') then raise exception 'Ese caballo no está disponible'; end if;
  insert into tcg_jugadas values (p_id, uid, p_c, p_h) on conflict (partida, jugador) do update set c = excluded.c, h = excluded.h;
  p := p || jsonb_build_object('listo' || lado, true, 'usados' || lado, (p->('usados' || lado)) || to_jsonb(p_c) || case when p_h is null then '[]'::jsonb else to_jsonb(p_h) end);
  if (p->'listoA')::text = 'true' and (p->'listoB')::text = 'true' then
    select * into ja from tcg_jugadas where partida = p_id and jugador = p->>'a';
    select * into jb from tcg_jugadas where partida = p_id and jugador = p->>'b';
    ua := suertes[1 + floor(random() * 16)::int]; ub := suertes[1 + floor(random() * 16)::int];
    ta := public.tcg_valor(ja.c, ja.h, f) + ua; tb := public.tcg_valor(jb.c, jb.h, f) + ub;
    oa := ta >= (f->>'b')::int; ob := tb >= (f->>'b')::int;
    s := case when p->>'modo' = 'suerte' then 1 else (f->>'s')::int end; bote := (p->>'bote')::int + s; sa := (p->>'sa')::int; sb := (p->>'sb')::int;
    w := case when oa and not ob then 'a' when ob and not oa then 'b' when oa and ob and ta > tb then 'a' when oa and ob and tb > ta then 'b' else null end;
    if w = 'a' then sa := sa + bote; bote := 0; elsif w = 'b' then sb := sb + bote; bote := 0; end if;
    p := p || jsonb_build_object('sa', sa, 'sb', sb, 'bote', bote, 'ronda', ronda + 1, 'listoA', false, 'listoB', false,
      'log', (p->'log') || jsonb_build_array(jsonb_build_object('ronda', ronda, 'ca', ja.c, 'ha', ja.h, 'cb', jb.c, 'hb', jb.h, 'ua', ua, 'ub', ub, 'ta', ta, 'tb', tb, 'w', w)));
    delete from tcg_jugadas where partida = p_id;
    if ronda + 1 >= total then
      ganador := case when sa > sb then p->>'a' when sb > sa then p->>'b' else null end;
      p := p || jsonb_build_object('estado', 'fin', 'ganador', ganador);
      perform public.tcg_resultado(p->>'a', ganador = p->>'a', case when ganador = p->>'a' then 10 else 2 end);
      perform public.tcg_resultado(p->>'b', ganador = p->>'b', case when ganador = p->>'b' then 10 else 2 end);
    end if;
  end if;
  update tcg_partidas set data = p where id = p_id;
end $$;

create or replace function public.tcg_abandonar(p_id text) returns void
language plpgsql security definer set search_path = public as $$
declare uid text := public.tcg_uid(); p jsonb; otro text;
begin
  select data into p from tcg_partidas where id = p_id for update;
  if p is null or uid not in (p->>'a', coalesce(p->>'b', '')) then raise exception 'No juegas en esta partida'; end if;
  if p->>'estado' = 'fin' then return; end if;
  otro := case when uid = p->>'a' then p->>'b' else p->>'a' end;
  update tcg_partidas set data = data || jsonb_build_object('estado', 'fin', 'ganador', otro, 'abandono', uid) where id = p_id;
  delete from tcg_jugadas where partida = p_id;
end $$;

-- Intercambio: como con los caballos, el dueño genera un código y quien lo escribe recibe la carta.
create or replace function public.tcg_transferir(p_id text) returns text
language plpgsql security definer set search_path = public as $$
declare uid text := public.tcg_uid(); k jsonb; cod text := public.tcg_codigo_nuevo('CARTA'); tipo text; quedan int;
begin
  select data into k from tcg_mis_cartas where id = p_id for update;
  if k is null or k->>'ownerId' <> uid then raise exception 'Esa carta no es tuya'; end if;
  select data->>'tipo' into tipo from tcg_catalogo where id = k->>'cardId';
  select count(distinct m.data->>'cardId') into quedan from tcg_mis_cartas m join tcg_catalogo c on c.id = m.data->>'cardId'
    where m.data->>'ownerId' = uid and m.id <> p_id and c.data->>'tipo' = tipo;
  if quedan < (case when tipo = 'charro' then 8 else 4 end) then raise exception 'Necesitas conservar 8 charros y 4 caballos distintos para jugar'; end if;
  update tcg_mis_cartas set data = data || jsonb_build_object('codigo', cod) where id = p_id;
  return cod;
end $$;

create or replace function public.tcg_recibir(p_codigo text) returns text
language plpgsql security definer set search_path = public as $$
declare uid text := public.tcg_uid(); r record; c text := upper(trim(p_codigo));
begin
  perform public.tcg_inicio();
  select id, data into r from tcg_mis_cartas where data->>'codigo' = c for update;
  if r.id is not null then
    if r.data->>'ownerId' = uid then raise exception 'Esa carta ya es tuya'; end if;
    update tcg_mis_cartas set data = (data - 'codigo') || jsonb_build_object('ownerId', uid, 'origen', 'intercambio') where id = r.id;
    return r.data->>'cardId';
  end if;
  select id, data into r from tcg_codigos where id = c for update;
  if r.id is null or (r.data->>'usado')::boolean then raise exception 'Código inválido o ya usado'; end if;
  update tcg_codigos set data = data || jsonb_build_object('usado', true, 'usadoPor', uid) where id = r.id;
  return public.tcg_dar(uid, r.data->>'cardId', 'impresa');
end $$;

-- Código de una carta impresa. Solo lo genera el súper usuario.
create or replace function public.tcg_crear_codigo(p_carta text) returns text
language plpgsql security definer set search_path = public as $$
declare cod text := public.tcg_codigo_nuevo('REAL');
begin
  if not public.is_super() then raise exception 'Solo el súper usuario'; end if;
  if not exists (select 1 from tcg_catalogo where id = p_carta) then raise exception 'Carta desconocida'; end if;
  insert into tcg_codigos (id, data) values (cod, jsonb_build_object('id', cod, 'cardId', p_carta, 'usado', false));
  return cod;
end $$;

-- Reparte plata y oro a los mejores por puntos. El banco nunca entrega más de 100 de plata ni 50 de oro.
create or replace function public.tcg_repartir(p_plata int, p_oro int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b jsonb; pl int; ou int; r record; dp int := 0; d_o int := 0;
begin
  if not public.is_super() then raise exception 'Solo el súper usuario'; end if;
  select data into b from settings where id = 'tcg_banco' for update;
  pl := least(greatest(p_plata, 0), (b->>'plata')::int); ou := least(greatest(p_oro, 0), (b->>'oro')::int);
  for r in select id from tcg_jugadores order by (data->>'puntos')::int desc, (data->>'partidas')::int desc limit greatest(pl, ou) loop
    if dp < pl then perform public.tcg_dar(r.id, public.tcg_al_azar('plata'), 'premio'); dp := dp + 1; end if;
    if d_o < ou then perform public.tcg_dar(r.id, public.tcg_al_azar('oro'), 'premio'); d_o := d_o + 1; end if;
  end loop;
  update settings set data = data || jsonb_build_object('plata', (b->>'plata')::int - dp, 'oro', (b->>'oro')::int - d_o) where id = 'tcg_banco';
  return jsonb_build_object('plata', dp, 'oro', d_o);
end $$;

do $$
declare f text;
begin
  foreach f in array array['tcg_uid()','tcg_codigo_nuevo(text)','tcg_dar(text,text,text)','tcg_al_azar(text)','tcg_resultado(text,boolean,int)','tcg_mazo_ok(text,jsonb)','tcg_valor(text,text,jsonb)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated';
  end loop;
  foreach f in array array['tcg_inicio()','tcg_premio(boolean,int)','tcg_crear_partida(text,int,jsonb)','tcg_unirse(text,jsonb)','tcg_jugar(text,text,text)','tcg_abandonar(text)','tcg_transferir(text)','tcg_recibir(text)','tcg_crear_codigo(text)','tcg_repartir(int,int)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;

do $$
declare t text;
begin
  foreach t in array array['tcg_mis_cartas','tcg_jugadores','tcg_partidas'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';

-- Debe mostrar 5 filas: 52 cartas, 6 tablas, 18 funciones y el banco con 100 y 50.
select 'catalogo' as cosa, count(*)::text as valor from tcg_catalogo
union all select 'tabla', count(*)::text from pg_tables where schemaname = 'public' and tablename like 'tcg\_%' and tablename <> 'tcg_cards'
union all select 'funciones', count(*)::text from pg_proc where proname like 'tcg\_%' and proname <> 'tcg_sync'
union all select 'plata', data->>'plata' from settings where id = 'tcg_banco'
union all select 'oro', data->>'oro' from settings where id = 'tcg_banco';
