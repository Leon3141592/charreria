#!/usr/bin/env python3
"""
Charros TCG: tarjetas digitales, microchips NFC y estadísticas.

Sigue los mismos nombres y reglas de Charrería Pro, para poder conectarse a sus datos:
  - Tipos de carta: charro, horse, stock. El id de carta es '<tipo>-<idDelRegistro>'.
  - Una carta existe si hay autorización, Pro vigente y registro oficial. Esa regla ya vive en
    tcg_sync() (actualizacion_tcg.sql) y en tcgSyncLocal() (index.html): si cambia, cambia en los tres.
  - El chip usa chipUid y chipStatus: pendiente, validado o rechazado.
  - Una monta tiene el id '<eventId>-<charroId>-<faena>': un caballo por charro y faena.

Los datos reales se cargan con cargar_cartas(), cargar_chips() y cargar_estadisticas(), que reciben un
RepositorioCharros (charros_pro_matrix/db_supabase.py). Solo leen: cartas, chips y montas los escribe la app.
El diseño visual de la carta no vive aquí; sigue siendo el `.tc` de la app.

Uso:  python3 tcg_logic.py     (muestra un ejemplo)
"""

from __future__ import annotations

import json
import re
import time
from collections import Counter
from dataclasses import asdict, dataclass, field

TIPOS = ("charro", "horse", "stock")
ESTADOS_CHIP = ("pendiente", "validado", "rechazado")


class ErrorTCG(Exception):
    """Error de negocio con un mensaje que se le puede mostrar al usuario."""


def ahora_ms() -> int:
    return int(time.time() * 1000)


def normalizar_uid(texto: str) -> str:
    """Igual que normUid() de la app: '04:a1:c2' se convierte en '04A1C2'."""
    return re.sub(r"[^0-9a-fA-F]", "", str(texto or "")).upper()


def formatear_uid(uid: str) -> str:
    """Igual que fmtUid() de la app: '04A1C2' se convierte en '04:A1:C2'."""
    limpio = normalizar_uid(uid)
    return ":".join(limpio[i:i + 2] for i in range(0, len(limpio), 2))


# --------------------------------------------------------------------------- tarjetas

@dataclass(frozen=True)
class Perfil:
    id: str
    tcg_consent: bool
    pro_activo: bool
    pro_hasta_ms: int


@dataclass(frozen=True)
class Registro:
    """Un charro, caballo o ganado de Charrería Pro."""
    id: str
    tipo: str
    nombre: str
    dueno_id: str
    oficial: bool           # resultado de isOfficial() / verif_key() en la app
    modo_stock: str = ""    # en ganado, solo 'unidad' puede tener carta


@dataclass(frozen=True)
class Carta:
    id: str
    tipo: str
    ref_id: str
    nombre: str
    dueno_id: str
    activa_hasta_ms: int

    def vigente(self, momento_ms: int | None = None) -> bool:
        return self.activa_hasta_ms > (ahora_ms() if momento_ms is None else momento_ms)


def motivo_sin_carta(registro: Registro, perfil: Perfil | None, momento_ms: int) -> str | None:
    """Devuelve por qué un registro no puede tener carta, o None si sí puede."""
    if registro.tipo not in TIPOS:
        return f"Tipo desconocido: {registro.tipo}"
    if perfil is None:
        return "El registro no tiene dueño"
    if not perfil.tcg_consent:
        return "El dueño no ha autorizado la carta"
    if not perfil.pro_activo or perfil.pro_hasta_ms <= momento_ms:
        return "El dueño no tiene Pro vigente"
    if not registro.oficial:
        return "El registro no está verificado como oficial"
    if registro.tipo == "stock" and registro.modo_stock != "unidad":
        return "Solo el ganado registrado por unidad tiene carta"
    return None


def crear_carta(registro: Registro, perfil: Perfil | None, momento_ms: int | None = None) -> Carta:
    momento = ahora_ms() if momento_ms is None else momento_ms
    motivo = motivo_sin_carta(registro, perfil, momento)
    if motivo:
        raise ErrorTCG(motivo)
    return Carta(f"{registro.tipo}-{registro.id}", registro.tipo, registro.id,
                 registro.nombre, perfil.id, perfil.pro_hasta_ms)


# --------------------------------------------------------------------------- microchips NFC

@dataclass
class Chip:
    uid: str
    tipo: str
    ref_id: str
    dueno_id: str
    estado: str = "pendiente"
    validado_por: str | None = None
    registrado_ms: int = field(default_factory=ahora_ms)


class RegistroChips:
    """
    Un chip por ejemplar y un ejemplar por chip.

    Aviso de seguridad: el UID se puede copiar. Sirve para identificar, no para demostrar
    autenticidad. Antes de ligar un chip a dinero o a cartas de valor conviene usar chips con
    firma criptográfica, como NTAG 424 DNA.
    """

    def __init__(self) -> None:
        self.por_uid: dict[str, Chip] = {}

    def registrar(self, uid: str, tipo: str, ref_id: str, usuario_id: str, dueno_id: str) -> Chip:
        limpio = normalizar_uid(uid)
        if not 8 <= len(limpio) <= 32:
            raise ErrorTCG("El UID debe tener entre 8 y 32 caracteres hexadecimales")
        if tipo not in ("horse", "stock"):
            raise ErrorTCG("Solo caballos y ganado llevan chip")
        if usuario_id != dueno_id:
            raise ErrorTCG("Solo el dueño registra el chip")
        actual = self.chip_de(tipo, ref_id)
        if actual and actual.estado == "validado":
            raise ErrorTCG("Este ejemplar ya tiene un chip validado")
        ocupado = self.por_uid.get(limpio)
        if ocupado and (ocupado.tipo, ocupado.ref_id) != (tipo, ref_id):
            raise ErrorTCG("Ese chip ya está registrado en otro ejemplar")
        if actual:
            del self.por_uid[actual.uid]  # reemplaza un chip pendiente o rechazado
        chip = Chip(limpio, tipo, ref_id, dueno_id)
        self.por_uid[limpio] = chip
        return chip

    def resolver(self, uid: str, aprobado: bool, validador: str, es_super: bool) -> Chip:
        """Solo el súper usuario valida o rechaza, igual que en la app."""
        if not es_super:
            raise ErrorTCG("Solo el súper usuario valida chips")
        chip = self.por_uid.get(normalizar_uid(uid))
        if chip is None:
            raise ErrorTCG("Chip desconocido")
        chip.estado = "validado" if aprobado else "rechazado"
        chip.validado_por = validador
        return chip

    def chip_de(self, tipo: str, ref_id: str) -> Chip | None:
        return next((c for c in self.por_uid.values() if (c.tipo, c.ref_id) == (tipo, ref_id)), None)

    def escanear(self, uid: str) -> Chip:
        """Lo que hace la mesa del juez: solo un chip validado identifica al ejemplar."""
        chip = self.por_uid.get(normalizar_uid(uid))
        if chip is None:
            raise ErrorTCG("Chip desconocido")
        if chip.estado != "validado":
            raise ErrorTCG(f"Chip {chip.estado}: no se puede usar")
        return chip


# --------------------------------------------------------------------------- estadísticas

@dataclass(frozen=True)
class Monta:
    event_id: str
    charro_id: str
    faena: str
    horse_id: str
    puntos: int = 0

    @property
    def id(self) -> str:
        return f"{self.event_id}-{self.charro_id}-{self.faena}"


class Estadisticas:
    """Acumula montas. Volver a registrar la misma faena la corrige; no la cuenta doble."""

    def __init__(self) -> None:
        self.montas: dict[str, Monta] = {}

    def registrar(self, monta: Monta, chips: RegistroChips) -> None:
        chip = chips.chip_de("horse", monta.horse_id)
        if chip is None or chip.estado != "validado":
            raise ErrorTCG("El caballo no tiene un chip validado")
        self.montas[monta.id] = monta

    def de_caballo(self, horse_id: str) -> dict:
        propias = [m for m in self.montas.values() if m.horse_id == horse_id]
        total = sum(m.puntos for m in propias)
        return {
            "horse_id": horse_id,
            "montas": len(propias),
            "eventos": len({m.event_id for m in propias}),
            "puntos": total,
            "promedio": round(total / len(propias), 2) if propias else 0,
            "por_faena": dict(Counter(m.faena for m in propias)),
        }

    def ranking(self, limite: int = 10) -> list[dict]:
        """Ordena por puntos totales y, en empate, por promedio."""
        caballos = {m.horse_id for m in self.montas.values()}
        tabla = [self.de_caballo(h) for h in caballos]
        tabla.sort(key=lambda f: (-f["puntos"], -f["promedio"], f["horse_id"]))
        return tabla[:limite]


# --------------------------------------------------------------------------- carga desde Supabase

def cargar_cartas(repositorio) -> list[Carta]:
    """Cartas vigentes del catálogo que mantienen los disparadores de la base."""
    cartas = [Carta(d["id"], d["kind"], d["refId"], d["name"], d["ownerId"], int(d["activeUntil"]))
              for d in repositorio.leer_datos("tcg_cards")]
    return [c for c in cartas if c.vigente()]


def cargar_chips(repositorio) -> RegistroChips:
    chips = RegistroChips()
    for tipo, tabla in (("horse", "horses"), ("stock", "stock")):
        for d in repositorio.leer_datos(tabla):
            uid = normalizar_uid(d.get("chipUid"))
            if uid and d.get("chipStatus") in ESTADOS_CHIP:
                chips.por_uid[uid] = Chip(uid, tipo, d["id"], d.get("ownerId", ""), d["chipStatus"],
                                          d.get("chipValidatedBy"), int(d.get("chipAt") or 0))
    return chips


def cargar_estadisticas(repositorio) -> Estadisticas:
    """
    Igual que la app: cada calificación se acredita al caballo escaneado en esa faena o, si no hubo
    escaneo, al caballo inscrito por el charro. Las montas históricas no exigen chip validado.
    """
    montas_nfc = {r["id"]: r["horseId"] for r in repositorio.leer_datos("horse_rides")}
    aprobados = {l["id"] for l in repositorio.leer_datos("lienzos") if l.get("status") == "aprobado"}
    eventos = {e["id"]: e for e in repositorio.leer_datos("events")
               if e.get("status") in ("en_vivo", "finalizado") and e.get("lienzoId") in aprobados}
    stats = Estadisticas()
    for s in repositorio.leer_datos("scores"):
        evento = eventos.get(s.get("eventId"))
        if evento is None:
            continue
        inscritos = {c["id"]: c for c in evento.get("charros", [])}
        for parte in s.get("parts", []):
            charro = inscritos.get(parte.get("id"))
            if charro is None:
                continue
            horse_id = montas_nfc.get(f"{s['eventId']}-{parte['id']}-{s['faena']}") or charro.get("horseId")
            if horse_id:
                monta = Monta(s["eventId"], parte["id"], s["faena"], horse_id, parte.get("pts", 0))
                stats.montas[monta.id] = monta
    return stats


# --------------------------------------------------------------------------- ejemplo

def _ejemplo() -> None:
    momento = ahora_ms()
    perfil = Perfil("u1", True, True, momento + 30 * 86_400_000)
    carta = crear_carta(Registro("cb1", "horse", "Relámpago", "u1", True), perfil, momento)
    print("Carta:", asdict(carta))

    chips = RegistroChips()
    chips.registrar("04:a1:c2:e3:f4:05:1a", "horse", "cb1", "u1", "u1")
    chip = chips.resolver("04A1C2E3F4051A", True, "Súper usuario", es_super=True)
    print("Chip:", formatear_uid(chip.uid), chip.estado)

    stats = Estadisticas()
    stats.registrar(Monta("ev1", "ch1", "cala", "cb1", 24), chips)
    stats.registrar(Monta("ev1", "ch1", "colas", "cb1", 18), chips)
    print("Ranking:", json.dumps(stats.ranking(), ensure_ascii=False))


if __name__ == "__main__":
    _ejemplo()
