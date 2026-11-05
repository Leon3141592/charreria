#!/usr/bin/env python3
"""
Sombra: monitoreo pasivo y defensa de Charros Pro.

Qué hace:
  - Lee lo que ya llega a NUESTROS sistemas: mensajes de la plataforma e intentos de acceso.
  - Detecta amenazas, extorsión, fraude, amaño de calificaciones y ataques web, aunque el texto
    venga disfrazado (m4t4r, m.a.t.a.r, letras cirílicas, caracteres invisibles).
  - Clasifica cada hallazgo y propone una respuesta proporcional a su gravedad.

Qué NO hace, por diseño:
  - No toca sistemas ajenos: no escanea, no contraataca ni "devuelve" ataques. Entrar a un equipo
    ajeno sin permiso puede ser delito (Código Penal Federal, art. 211 bis 1) aunque sea en respuesta
    a un ataque, y además puede golpear a un inocente cuya máquina fue usada de puente.
  - "Respuesta simétrica" significa aquí proporcional: a mayor gravedad, más defensa propia.
  - No ejecuta bloqueos. Los propone, y una persona los aprueba.

El análisis es por reglas: orienta, pero tiene falsos positivos y falsos negativos. Nada de lo que
marque Sombra debe sancionar a alguien sin que una persona lo revise.

Uso:  python3 sombra_core.py     (muestra un ejemplo y no escribe nada)
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
import unicodedata
from collections import defaultdict, deque
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

BASE = Path(__file__).resolve().parent
sys.path.insert(0, str(BASE.parent / "charros_pro_matrix"))
from supabase_client import ClienteSupabase, ErrorSupabase  # noqa: E402

RUTA_DATOS = BASE / "datos"

# --------------------------------------------------------------------------- normalización antievasión

# Letras de otros alfabetos que se ven iguales a las latinas.
HOMOGLIFOS = str.maketrans({
    "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "х": "x", "у": "y", "і": "i", "ѕ": "s",
    "α": "a", "ο": "o", "ε": "e", "ι": "i", "κ": "k", "ν": "v", "τ": "t", "ρ": "p",
})
LEET = str.maketrans({
    "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "8": "b",
    "@": "a", "$": "s", "!": "i", "|": "l",
})
SEPARADORES = r"[\s.\-_*·,~+/\\]+"


def normalizar(texto: str) -> str:
    """Reduce un texto a su forma básica, para que un disfraz no cambie lo que se compara."""
    t = unicodedata.normalize("NFKC", texto).casefold().translate(HOMOGLIFOS)
    t = unicodedata.normalize("NFKD", t)
    # Quita acentos (Mn) y caracteres invisibles como el espacio de ancho cero (Cf).
    t = "".join(c for c in t if unicodedata.category(c) not in ("Mn", "Cf"))
    t = t.translate(LEET)
    # Une letras sueltas: 'm a t a r' y 'm.a.t.a.r' se vuelven 'matar'.
    t = re.sub(rf"(?<![a-z])[a-z](?:{SEPARADORES}[a-z])+(?![a-z])",
               lambda m: re.sub(SEPARADORES, "", m.group(0)), t)
    t = re.sub(r"(.)\1+", r"\1", t)        # 'maaatar' se vuelve 'matar'
    t = re.sub(r"[^a-z ]+", " ", t)
    return re.sub(r" +", " ", t).strip()


# --------------------------------------------------------------------------- catálogo de señales

# Son frases y no palabras sueltas a propósito: en charrería "paso de la muerte", "toro" o "tirar"
# son vocabulario normal y no deben disparar nada. El peso va de 1 a 5.
FRASES = {
    "amenaza": (5, [
        "te voy a matar", "te vamos a matar", "te vamos a levantar", "vas a morir",
        "sabemos donde vives", "se donde vives", "te va a pasar algo", "cuida a tu familia",
    ]),
    "extorsion": (4, [
        "cuota de piso", "derecho de piso", "te conviene pagar", "paga o te", "pagas o te", "deposita o te",
    ]),
    "amano": (3, [
        "comprar al juez", "arreglar la calificacion", "subir la calificacion por", "soborno",
        "mordida al juez", "arreglar el resultado",
    ]),
    "fraude": (3, [
        "verifica tu cuenta", "confirma tu contrasena", "manda tu contrasena", "tu codigo de verificacion",
        "manda tu nip", "transferencia urgente", "pago por fuera de la plataforma",
    ]),
}
# Se revisan sobre el texto original: normalizarlos destruiría justo lo que los delata.
ATAQUES_WEB = (5, [
    r"\bunion\s+(all\s+)?select\b", r"\bdrop\s+table\b", r"'\s*or\s+'?1'?\s*=\s*'?1",
    r"<\s*script\b", r"\bjavascript\s*:", r"\.\./\.\./",
])
LARGO_MIN_COMPACTO = 10  # las frases cortas sin espacios darían coincidencias por accidente


def _compilar() -> list[tuple[str, int, str, re.Pattern]]:
    catalogo = []
    for categoria, (peso, frases) in FRASES.items():
        for frase in frases:
            base = normalizar(frase)  # pasa por el mismo filtro que los mensajes
            catalogo.append((categoria, peso, base, re.compile(rf"(?<![a-z]){re.escape(base)}(?![a-z])")))
    return catalogo


CATALOGO = _compilar()
PATRONES_WEB = [re.compile(p, re.IGNORECASE) for p in ATAQUES_WEB[1]]


# --------------------------------------------------------------------------- hallazgos y respuesta

NIVELES = {0: "limpio", 1: "bajo", 2: "medio", 3: "alto", 4: "critico"}

# Respuesta proporcional. Todo ocurre dentro de nuestros propios sistemas.
PROTOCOLOS = {
    0: [],
    1: ["Registrar en bitácora"],
    2: ["Registrar en bitácora", "Poner en revisión del moderador"],
    3: ["Registrar en bitácora", "Avisar al administrador", "Proponer limitar la cuenta u origen",
        "Conservar evidencia"],
    4: ["Registrar en bitácora", "Avisar al administrador de inmediato",
        "Proponer bloquear la cuenta u origen en nuestros sistemas", "Conservar evidencia",
        "Valorar denuncia: Policía Cibernética (088) o 911 si hay riesgo a una persona"],
}


@dataclass
class Hallazgo:
    origen: str
    tipo: str                 # texto o acceso
    nivel: int
    nivel_nombre: str
    categorias: list[str]
    senales: list[str]
    respuesta: list[str]
    requiere_aprobacion_humana: bool
    huella_sha256: str = ""   # prueba de qué se analizó sin copiar el contenido a la bitácora
    fecha: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat(timespec="seconds"))


def nivel_por_peso(peso: int) -> int:
    if peso >= 5:
        return 4
    if peso == 4:
        return 3
    if peso == 3:
        return 2
    return 1 if peso > 0 else 0


def armar_hallazgo(origen: str, tipo: str, peso: int, categorias, senales, huella: str = "") -> Hallazgo:
    nivel = nivel_por_peso(peso)
    return Hallazgo(origen, tipo, nivel, NIVELES[nivel], sorted(set(categorias)), senales,
                    PROTOCOLOS[nivel], requiere_aprobacion_humana=nivel >= 3, huella_sha256=huella)


# --------------------------------------------------------------------------- análisis

def analizar_texto(texto: str, origen: str = "desconocido") -> Hallazgo:
    """Busca señales en un mensaje. Manda la señal más grave; varias señales suben un punto."""
    normal = normalizar(texto)
    compacto = normal.replace(" ", "")
    categorias, senales, pesos = [], [], []

    for categoria, peso, frase, patron in CATALOGO:
        sin_espacios = frase.replace(" ", "")
        if patron.search(normal) or (len(sin_espacios) >= LARGO_MIN_COMPACTO and sin_espacios in compacto):
            categorias.append(categoria)
            senales.append(frase)
            pesos.append(peso)

    for patron in PATRONES_WEB:
        if patron.search(texto):
            categorias.append("ataque_web")
            senales.append(patron.pattern)
            pesos.append(ATAQUES_WEB[0])

    peso = min(max(pesos, default=0) + (1 if len(set(categorias)) > 1 else 0), 5)
    huella = hashlib.sha256(texto.encode("utf-8")).hexdigest()
    return armar_hallazgo(origen, "texto", peso, categorias, senales, huella)


class MonitorAccesos:
    """Cuenta inicios de sesión fallidos por origen, dentro de una ventana de tiempo."""

    def __init__(self, umbral: int = 5, critico: int = 20, ventana_seg: int = 300):
        self.umbral, self.critico, self.ventana = umbral, critico, ventana_seg
        self.fallos: dict[str, deque[float]] = defaultdict(deque)

    def registrar(self, origen: str, exito: bool, momento: float) -> Hallazgo | None:
        """`momento` va en segundos. Devuelve un hallazgo solo si se cruza un umbral."""
        if exito:
            return None
        fallos = self.fallos[origen]
        fallos.append(momento)
        while fallos and momento - fallos[0] > self.ventana:
            fallos.popleft()
        n = len(fallos)
        if n not in (self.umbral, self.critico):   # avisa al cruzar, no en cada intento
            return None
        peso = 5 if n == self.critico else 4
        senal = f"{n} fallos en {self.ventana} segundos"
        return armar_hallazgo(origen, "acceso", peso, ["fuerza_bruta"], [senal])


class Bitacora:
    """Registro de solo agregar. Sin `ruta` vive en memoria. Nunca guarda el texto original."""

    def __init__(self, ruta: Path | None = None):
        self.ruta = ruta
        self.memoria: list[dict] = []

    def agregar(self, hallazgo: Hallazgo) -> None:
        if hallazgo.nivel == 0:
            return
        registro = asdict(hallazgo)
        if self.ruta is None:
            self.memoria.append(registro)
            return
        self.ruta.parent.mkdir(parents=True, exist_ok=True)
        with open(self.ruta, "a", encoding="utf-8") as f:
            f.write(json.dumps(registro, ensure_ascii=False) + "\n")


class BitacoraSupabase(Bitacora):
    """Bitácora de REAL. Si la base falla guarda en archivo local: una alerta no se debe perder."""

    def __init__(self, cliente: ClienteSupabase, ruta_respaldo: Path):
        super().__init__(ruta_respaldo)
        self.cliente = cliente

    def agregar(self, hallazgo: Hallazgo) -> None:
        if hallazgo.nivel == 0:
            return
        try:
            self.cliente.insertar("sombra_hallazgos", {
                "nivel": hallazgo.nivel, "origen": hallazgo.origen,
                "tipo": hallazgo.tipo, "data": asdict(hallazgo)})
        except ErrorSupabase as e:
            print(f"Sombra: hallazgo guardado solo en local ({e})", file=sys.stderr)
            super().agregar(hallazgo)


class Sombra:
    """Punto de entrada: analiza, registra y devuelve el hallazgo para que una persona decida."""

    def __init__(self, modo: str = "DEMO", bitacora: Bitacora | None = None):
        self.modo = modo
        ruta = RUTA_DATOS / f"bitacora_{modo.lower()}.jsonl"
        if bitacora is not None:
            self.bitacora = bitacora
        elif modo == "REAL":
            self.bitacora = BitacoraSupabase(ClienteSupabase.desde_entorno(), ruta)
        else:
            self.bitacora = Bitacora(ruta)
        self.accesos = MonitorAccesos()

    def revisar_mensaje(self, texto: str, origen: str) -> Hallazgo:
        hallazgo = analizar_texto(texto, origen)
        self.bitacora.agregar(hallazgo)
        return hallazgo

    def revisar_acceso(self, origen: str, exito: bool, momento: float) -> Hallazgo | None:
        hallazgo = self.accesos.registrar(origen, exito, momento)
        if hallazgo:
            self.bitacora.agregar(hallazgo)
        return hallazgo


# --------------------------------------------------------------------------- ejemplo

def _ejemplo() -> None:
    sombra = Sombra("DEMO", Bitacora())  # bitácora en memoria: no toca ningún archivo
    mensajes = [
        "Qué gran paso de la muerte, casi tira al toro en la cala",
        "t3 v0y a m4t4r",
        "t e  v o y  a  m a t a r",
        "Te conviene pagar la cuota de piso",
        "Veriﬁca tu cuenta aquí",
        "' OR '1'='1",
    ]
    for texto in mensajes:
        h = sombra.revisar_mensaje(texto, "demo")
        print(f"[{h.nivel_nombre:7}] {texto!r} -> {h.categorias}")
    for i in range(5):
        h = sombra.revisar_acceso("203.0.113.7", False, float(i))
    print(f"[{h.nivel_nombre:7}] {h.senales[0]} -> {h.respuesta}")


if __name__ == "__main__":
    _ejemplo()
