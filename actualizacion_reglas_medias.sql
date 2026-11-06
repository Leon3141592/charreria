-- =====================================================================
-- CHARRERÍA PRO — Actualización: CharreríaTCG se juega sumando Medias
-- Pega todo este archivo en Supabase > SQL Editor > New query > Run y confirma con "Run query" si aparece.
-- Se puede correr varias veces. No borra partidas, cartas ni jugadores.
-- =====================================================================

-- La Media de cada carta del juego. Debe coincidir con jBaseDatos() en index.html.
update public.tcg_catalogo c set data = c.data || jsonb_build_object('media', v.media)
from (values
  ('c01', 49),
  ('c02', 50),
  ('c03', 51),
  ('c04', 52),
  ('c05', 53),
  ('c06', 54),
  ('c07', 55),
  ('c08', 46),
  ('c09', 47),
  ('c10', 49),
  ('c11', 50),
  ('c12', 51),
  ('c13', 62),
  ('c14', 63),
  ('c15', 56),
  ('c16', 57),
  ('c17', 58),
  ('c18', 59),
  ('c19', 60),
  ('c20', 58),
  ('c21', 59),
  ('c22', 60),
  ('c23', 71),
  ('c24', 72),
  ('c25', 73),
  ('c26', 74),
  ('c27', 75),
  ('c28', 76),
  ('c29', 77),
  ('c30', 71),
  ('c31', 80),
  ('c32', 81),
  ('c33', 82),
  ('c34', 83),
  ('c35', 84),
  ('c36', 85),
  ('h01', 54),
  ('h02', 55),
  ('h03', 46),
  ('h04', 47),
  ('h05', 48),
  ('h06', 49),
  ('h07', 56),
  ('h08', 57),
  ('h09', 58),
  ('h10', 56),
  ('h11', 69),
  ('h12', 70),
  ('h13', 71),
  ('h14', 72),
  ('h15', 87),
  ('h16', 88)
) as v(id, media) where c.id = v.id;

create or replace function public.tcg_media(cid text) returns int
language sql stable set search_path = public as $$
  select coalesce((select (data->>'media')::int from tcg_catalogo where id = cid), 0)
$$;

-- La charreada ahora incluye el jineteo de yegua (índice 7).
create or replace function public.tcg_faena(i int) returns jsonb
language sql immutable as $$
  select ('[{"stat":"rienda","caballo":true,"s":1},{"stat":"reata","caballo":true,"s":1},{"stat":"rienda","caballo":true,"s":1},{"stat":"jineteo","caballo":false,"s":1},{"stat":"reata","caballo":false,"s":1},{"stat":"reata","caballo":true,"s":1},{"stat":"jineteo","caballo":true,"s":3},{"stat":"jineteo","caballo":false,"s":1}]'::jsonb)->i
$$;

create or replace function public.tcg_crear_partida(p_modo text, p_faena int, p_mazo jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare uid text := public.tcg_uid(); i text := 'p' || substr(md5(random()::text || clock_timestamp()::text), 1, 14); cod text := public.tcg_codigo_nuevo('RETA'); nom text;
begin
  perform public.tcg_inicio();
  if p_modo not in ('charreada', 'suerte') or p_faena not between 0 and 7 then raise exception 'Modo inválido'; end if;
  perform public.tcg_mazo_ok(uid, p_mazo);
  select data->>'name' into nom from tcg_jugadores where id = uid;
  insert into tcg_partidas (id, data) values (i, jsonb_build_object('id', i, 'codigo', cod, 'modo', p_modo, 'faena', p_faena, 'a', uid, 'aNombre', nom, 'b', null, 'estado', 'esperando',
    'ronda', 0, 'mazoA', p_mazo, 'usadosA', '[]'::jsonb, 'usadosB', '[]'::jsonb, 'listoA', false, 'listoB', false, 'sa', 0, 'sb', 0, 'bote', 0, 'log', '[]'::jsonb, 'at', (extract(epoch from now()) * 1000)::bigint));
  return i;
end $$;

-- Media del charro + Media del caballo + Media del ganado. Gana el total más alto.
create or replace function public.tcg_jugar(p_id text, p_c text, p_h text) returns void
language plpgsql security definer set search_path = public as $$
declare uid text := public.tcg_uid(); p jsonb; lado text; f jsonb; ja record; jb record; ta int; tb int; s int; bote int; w text; sa int; sb int; ronda int; total int; ganado int[] := array[46,55,62,70,82,92]; orden int[] := array[0,1,2,3,7,4,5,6]; ia int; ib int; ua int := 0; ub int := 0; ganador text;
begin
  select data into p from tcg_partidas where id = p_id for update;
  if p is null or p->>'estado' <> 'jugando' then raise exception 'La partida no está activa'; end if;
  lado := case uid when p->>'a' then 'A' when p->>'b' then 'B' else null end;
  if lado is null then raise exception 'No juegas en esta partida'; end if;
  if (p->('listo' || lado))::text = 'true' then raise exception 'Ya jugaste esta faena'; end if;
  ronda := (p->>'ronda')::int; total := case when p->>'modo' = 'suerte' then 3 else 8 end;
  f := public.tcg_faena(case when p->>'modo' = 'suerte' then (p->>'faena')::int else orden[ronda + 1] end);
  if not (p->('mazo' || lado)) ? p_c or p->('usados' || lado) ? p_c or left(p_c, 1) <> 'c' then raise exception 'Esa carta no está disponible'; end if;
  if p_h is not null and (not (f->>'caballo')::boolean or not (p->('mazo' || lado)) ? p_h or p->('usados' || lado) ? p_h or left(p_h, 1) <> 'h') then raise exception 'Ese caballo no está disponible'; end if;
  insert into tcg_jugadas values (p_id, uid, p_c, p_h) on conflict (partida, jugador) do update set c = excluded.c, h = excluded.h;
  p := p || jsonb_build_object('listo' || lado, true, 'usados' || lado, (p->('usados' || lado)) || to_jsonb(p_c) || case when p_h is null then '[]'::jsonb else to_jsonb(p_h) end);
  if (p->'listoA')::text = 'true' and (p->'listoB')::text = 'true' then
    select * into ja from tcg_jugadas where partida = p_id and jugador = p->>'a';
    select * into jb from tcg_jugadas where partida = p_id and jugador = p->>'b';
    if f->>'stat' = 'jineteo' then ia := 1 + floor(random() * 6)::int; ib := 1 + floor(random() * 5)::int; if ib >= ia then ib := ib + 1; end if; ua := ganado[ia]; ub := ganado[ib]; end if;
    ta := public.tcg_media(ja.c) + public.tcg_media(ja.h) + ua; tb := public.tcg_media(jb.c) + public.tcg_media(jb.h) + ub;
        s := case when p->>'modo' = 'suerte' then 1 else (f->>'s')::int end; bote := (p->>'bote')::int + s; sa := (p->>'sa')::int; sb := (p->>'sb')::int;
    w := case when ta > tb then 'a' when tb > ta then 'b' else null end;
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

revoke all on function public.tcg_media(text) from public, anon;
grant execute on function public.tcg_media(text) to authenticated;

notify pgrst, 'reload schema';

-- Debe mostrar 52 cartas con Media.
select count(*) as cartas_con_media from public.tcg_catalogo where data ? 'media';
