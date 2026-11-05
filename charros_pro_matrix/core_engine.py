#!/usr/bin/env python3
"""
Charros Pro: motor central del "CEO IA".

Qué hace, en orden, al cerrar un periodo de un lienzo:
  1. Filtro de medibilidad: solo cuenta ingresos con fuente y comprobante verificables.
  2. Cuota base: los primeros $10,000 MXN medibles cubren la cuota del lienzo.
  3. Excedente: lo que pasa de la cuota base.
  4. Reparto del excedente: 6% Dueño, 5% Cómputo Local, 5% Fondo Global y el 84% restante al lienzo.
  5. Asiento: DEMO lo guarda en un archivo local y REAL en Supabase.

Importante:
  - El motor CALCULA y REGISTRA. No mueve dinero ni se conecta a ningún banco.
  - Son reglas fijas y auditables; aquí no decide ningún modelo de lenguaje.
  - Todo el dinero se maneja en centavos enteros: nunca se usa float.

Uso:
    python3 core_engine.py              muestra un ejemplo y no escribe nada
    python3 core_engine.py --verificar  comprueba la conexión con Supabase
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

from db_supabase import ErrorDuplicado, ErrorSupabase, RepositorioCharros

BASE = Path(__file__).resolve().parent
RUTA_CONFIG = BASE / "config.json"
RUTA_DATOS = BASE / "datos"
MODOS = ("DEMO", "REAL")

# Regla sellada. config.json debe coincidir o el motor no arranca. Cambiarla exige modificar a
# propósito este bloque y las restricciones de actualizacion_matriz.sql.
CUOTA_BASE_SELLADA = Decimal("10000")
PORCENTAJE_SELLADO = Decimal("16")
REPARTO_SELLADO = {"dueno": Decimal("6"), "computo_local": Decimal("5"), "fondo_global": Decimal("5")}


class ErrorMotor(Exception):
    """Error de negocio con un mensaje que se le puede mostrar al usuario."""


# --------------------------------------------------------------------------- dinero

def a_centavos(monto) -> int:
    """Convierte '1234.56' a 123456. Rechaza float para no arrastrar errores de redondeo."""
    if isinstance(monto, float):
        raise ErrorMotor("Los montos deben llegar como texto o Decimal, no como float.")
    return int((Decimal(str(monto)) * 100).quantize(Decimal(1), rounding=ROUND_HALF_UP))


def a_pesos(centavos: int) -> str:
    """Convierte 123456 a '1234.56'."""
    signo = "-" if centavos < 0 else ""
    return f"{signo}{abs(centavos) // 100}.{abs(centavos) % 100:02d}"


def repartir_exacto(total: int, pesos: dict[str, Decimal]) -> dict[str, int]:
    """
    Reparte `total` centavos en proporción a `pesos` sin perder ni inventar un centavo.
    Usa el método del mayor residuo: redondea hacia abajo y entrega los centavos
    sobrantes a quienes tenían la fracción más grande.
    """
    suma = sum(pesos.values())
    exactos = {k: Decimal(total) * p / suma for k, p in pesos.items()}
    partes = {k: int(v) for k, v in exactos.items()}
    sobrante = total - sum(partes.values())
    por_fraccion = sorted(pesos, key=lambda k: exactos[k] - partes[k], reverse=True)
    for k in por_fraccion[:sobrante]:
        partes[k] += 1
    return partes


# --------------------------------------------------------------------------- configuración y modo

def cargar_config(ruta: Path = RUTA_CONFIG) -> dict:
    """Lee config.json y se niega a seguir si las reglas financieras no cuadran."""
    with open(ruta, encoding="utf-8") as f:
        config = json.load(f)
    fin = config["finanzas"]
    reparto = {k: Decimal(v) for k, v in fin["reparto_excedente"].items()}
    if (Decimal(fin["cuota_base_lienzo"]) != CUOTA_BASE_SELLADA
            or Decimal(fin["porcentaje_excedente"]) != PORCENTAJE_SELLADO
            or reparto != REPARTO_SELLADO):
        raise ErrorMotor("config.json no coincide con la regla financiera sellada.")
    if config["modo"] not in MODOS:
        raise ErrorMotor(f"Modo desconocido: {config['modo']}")
    return config


def credenciales_faltantes(config: dict) -> list[str]:
    """Variables de entorno que hacen falta para operar en REAL."""
    return [n for n in config["credenciales"]["requeridas_real"] if not os.environ.get(n)]


def leer_modo(ruta: Path = RUTA_CONFIG) -> str:
    return cargar_config(ruta)["modo"]


def cambiar_modo(modo: str, ruta: Path = RUTA_CONFIG) -> str:
    """
    Selector DEMO/REAL, la única puerta para cambiar de entorno.
    Para entrar a REAL exige credenciales: si faltan, se queda en el modo actual.
    """
    modo = str(modo).upper()
    if modo not in MODOS:
        raise ErrorMotor(f"Modo desconocido: {modo}")
    config = cargar_config(ruta)
    if modo == "REAL":
        faltan = credenciales_faltantes(config)
        if faltan:
            raise ErrorMotor("No se puede entrar a REAL. Faltan: " + ", ".join(faltan))
    config["modo"] = modo
    # Escritura atómica: un corte de luz no puede dejar config.json a medias.
    fd, temporal = tempfile.mkstemp(dir=ruta.parent, suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(config, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(temporal, ruta)
    return modo


# --------------------------------------------------------------------------- modelos

@dataclass(frozen=True)
class Ingreso:
    """Un ingreso reportado. `monto` va como texto ('1500.00') y `fecha` como 'AAAA-MM-DD'."""
    referencia: str      # folio del comprobante; también sirve para detectar duplicados
    monto: str
    fuente: str          # banco, pasarela_pago, taquilla_electronica (o demo)
    fecha: str
    concepto: str = ""
    moneda: str = "MXN"
    estimado: bool = False  # una proyección o promesa de pago nunca es medible


@dataclass
class Rechazo:
    referencia: str
    monto: str
    motivo: str


@dataclass
class Liquidacion:
    """Resultado de un cierre. Los montos van en pesos, como texto, para no perder precisión."""
    modo: str
    lienzo_id: str
    periodo: str
    ingreso_medible: str
    cuota_base_cubierta: str
    cuota_base_faltante: str
    excedente: str
    excedente_16: str
    dueno_6: str
    computo_local_5: str
    fondo_global_5: str
    lienzo_84: str              # lo que queda del excedente después del 16%
    total_lienzo: str           # cuota base cubierta + lienzo_84
    rechazados: list[Rechazo] = field(default_factory=list)
    cerrado_en: str = ""


# --------------------------------------------------------------------------- filtro de medibilidad

def fecha_en_periodo(fecha: str, periodo: str) -> bool:
    try:
        return datetime.strptime(fecha, "%Y-%m-%d").strftime("%Y-%m") == periodo
    except ValueError:
        return False


def filtrar_medibles(ingresos: list[Ingreso], periodo: str, modo: str, config: dict):
    """
    Separa lo medible de lo que no lo es. "Si no se puede comprobar, no existe":
    un ingreso rechazado no entra al cálculo y queda con su motivo en la liquidación.
    """
    clave = "fuentes_real" if modo == "REAL" else "fuentes_demo"
    fuentes = set(config["medibilidad"][clave])
    medibles, rechazados, vistos = [], [], set()

    for ing in ingresos:
        motivo = None
        try:
            centavos = a_centavos(ing.monto)
        except (ArithmeticError, ValueError, ErrorMotor):
            centavos = None
        if not ing.referencia.strip():
            motivo = "Sin referencia o comprobante"
        elif ing.referencia in vistos:
            motivo = "Referencia duplicada"
        elif centavos is None or centavos <= 0:
            motivo = "Monto inválido"
        elif ing.moneda != config["moneda"]:
            motivo = f"Moneda distinta de {config['moneda']}"
        elif ing.estimado:
            motivo = "Es una estimación, no un cobro"
        elif ing.fuente not in fuentes:
            motivo = f"Fuente no verificable en {modo}: {ing.fuente or 'vacía'}"
        elif not fecha_en_periodo(ing.fecha, periodo):
            motivo = f"Fuera del periodo {periodo}"

        if motivo:
            rechazados.append(Rechazo(ing.referencia, ing.monto, motivo))
        else:
            vistos.add(ing.referencia)
            medibles.append((ing, centavos))
    return medibles, rechazados


# --------------------------------------------------------------------------- cálculo financiero

def calcular_reparto(ingreso_centavos: int, finanzas: dict) -> dict[str, int]:
    """
    La regla financiera, como función pura y en centavos:

        cuota cubierta = mínimo(ingreso, 10,000)
        excedente      = ingreso - cuota cubierta
        16%            = excedente x 0.16, repartido en 6 / 5 / 5
        lienzo 84%     = excedente - 16%
    """
    cuota = a_centavos(finanzas["cuota_base_lienzo"])
    cubierta = min(ingreso_centavos, cuota)
    excedente = ingreso_centavos - cubierta

    porcentaje = Decimal(finanzas["porcentaje_excedente"])
    total_16 = int((Decimal(excedente) * porcentaje / 100).quantize(Decimal(1), rounding=ROUND_HALF_UP))
    pesos = {k: Decimal(v) for k, v in finanzas["reparto_excedente"].items()}
    partes = repartir_exacto(total_16, pesos)

    resultado = {
        "cuota_cubierta": cubierta,
        "cuota_faltante": cuota - cubierta,
        "excedente": excedente,
        "total_16": total_16,
        **partes,
        "lienzo_84": excedente - total_16,
    }
    # Candado: cada centavo que entró tiene que estar en exactamente un lugar.
    if cubierta + sum(partes.values()) + resultado["lienzo_84"] != ingreso_centavos:
        raise ErrorMotor("El reparto no cuadra con el ingreso.")
    return resultado


# --------------------------------------------------------------------------- libro de cierres

class Libro:
    """
    Registro de cierres, solo de agregar (JSON Lines), con un archivo por modo para que
    DEMO y REAL nunca se mezclen. Sin `ruta` vive en memoria: sirve para simular.
    """

    def __init__(self, ruta: Path | None = None):
        self.ruta = ruta
        self.memoria: list[dict] = []

    def asientos(self) -> list[dict]:
        if self.ruta is None:
            return list(self.memoria)
        if not self.ruta.exists():
            return []
        with open(self.ruta, encoding="utf-8") as f:
            return [json.loads(linea) for linea in f if linea.strip()]

    def ya_cerrado(self, lienzo_id: str, periodo: str) -> bool:
        return any(a["lienzo_id"] == lienzo_id and a["periodo"] == periodo for a in self.asientos())

    def agregar(self, asiento: dict, transacciones: list[dict]) -> None:
        asiento = {**asiento, "transacciones": transacciones}
        if self.ruta is None:
            self.memoria.append(asiento)
            return
        self.ruta.parent.mkdir(parents=True, exist_ok=True)
        with open(self.ruta, "a", encoding="utf-8") as f:
            f.write(json.dumps(asiento, ensure_ascii=False) + "\n")
            f.flush()
            os.fsync(f.fileno())


class LibroSupabase:
    """Libro de REAL. La base impide cerrar dos veces y rechaza un reparto que no cumpla la regla."""

    def __init__(self, repositorio: RepositorioCharros):
        self.repositorio = repositorio

    def ya_cerrado(self, lienzo_id: str, periodo: str) -> bool:
        try:
            return self.repositorio.cierre_existe(lienzo_id, periodo)
        except ErrorSupabase as e:
            raise ErrorMotor(str(e)) from None

    def agregar(self, asiento: dict, transacciones: list[dict]) -> None:
        fila = {
            "id": f"{asiento['lienzo_id']}-{asiento['periodo']}",
            "lienzo_id": asiento["lienzo_id"],
            "periodo": asiento["periodo"],
            "ingreso_centavos": a_centavos(asiento["ingreso_medible"]),
            "cuota_centavos": a_centavos(asiento["cuota_base_cubierta"]),
            "excedente_centavos": a_centavos(asiento["excedente"]),
            "dueno_centavos": a_centavos(asiento["dueno_6"]),
            "computo_centavos": a_centavos(asiento["computo_local_5"]),
            "fondo_centavos": a_centavos(asiento["fondo_global_5"]),
            "lienzo_centavos": a_centavos(asiento["lienzo_84"]),
            "data": asiento,
        }
        try:
            self.repositorio.registrar_cierre(fila, transacciones)
        except ErrorDuplicado as e:
            if "matriz_comprobante_unico" in str(e):
                raise ErrorMotor("Un comprobante de este cierre ya se usó en otro. No se guardó nada.") from None
            raise ErrorMotor(f"{asiento['lienzo_id']} ya tiene cerrado {asiento['periodo']}.") from None
        except ErrorSupabase as e:
            raise ErrorMotor(f"El cierre no quedó confirmado: {e}") from None


# --------------------------------------------------------------------------- CEO IA

class CEOIA:
    """Orquesta el cierre de un periodo. El modo se fija al crearlo y no cambia a medio cierre."""

    def __init__(self, config: dict | None = None, libro: Libro | LibroSupabase | None = None):
        self.config = config or cargar_config()
        self.modo = self.config["modo"]
        if self.modo == "REAL":
            faltan = credenciales_faltantes(self.config)
            if faltan:
                raise ErrorMotor("REAL sin credenciales. Faltan: " + ", ".join(faltan))
        if libro is not None:
            self.libro = libro
        elif self.modo == "REAL":
            # Sin respaldo local a propósito: si la base no responde, REAL no cierra.
            try:
                self.libro = LibroSupabase(RepositorioCharros.desde_entorno())
            except ErrorSupabase as e:
                raise ErrorMotor(str(e)) from None
        else:
            self.libro = Libro(RUTA_DATOS / "libro_demo.jsonl")

    def cerrar_periodo(self, lienzo_id: str, periodo: str, ingresos: list[Ingreso]) -> Liquidacion:
        """Cierra un lienzo en un periodo mensual ('AAAA-MM'). Un periodo solo se cierra una vez."""
        try:
            datetime.strptime(periodo, "%Y-%m")
        except ValueError:
            raise ErrorMotor(f"Periodo inválido: {periodo}. Usa AAAA-MM.") from None
        if self.libro.ya_cerrado(lienzo_id, periodo):
            raise ErrorMotor(f"{lienzo_id} ya tiene cerrado {periodo}.")

        medibles, rechazados = filtrar_medibles(ingresos, periodo, self.modo, self.config)
        total = sum(centavos for _, centavos in medibles)
        transacciones = [
            {"referencia": i.referencia, "monto_centavos": centavos, "fuente": i.fuente,
             "fecha": i.fecha, "concepto": i.concepto}
            for i, centavos in medibles
        ]
        r = calcular_reparto(total, self.config["finanzas"])

        liquidacion = Liquidacion(
            modo=self.modo,
            lienzo_id=lienzo_id,
            periodo=periodo,
            ingreso_medible=a_pesos(total),
            cuota_base_cubierta=a_pesos(r["cuota_cubierta"]),
            cuota_base_faltante=a_pesos(r["cuota_faltante"]),
            excedente=a_pesos(r["excedente"]),
            excedente_16=a_pesos(r["total_16"]),
            dueno_6=a_pesos(r["dueno"]),
            computo_local_5=a_pesos(r["computo_local"]),
            fondo_global_5=a_pesos(r["fondo_global"]),
            lienzo_84=a_pesos(r["lienzo_84"]),
            total_lienzo=a_pesos(r["cuota_cubierta"] + r["lienzo_84"]),
            rechazados=rechazados,
            cerrado_en=datetime.now(timezone.utc).isoformat(timespec="seconds"),
        )
        self.libro.agregar(asdict(liquidacion), transacciones)
        return liquidacion


# --------------------------------------------------------------------------- ejemplo

def _ejemplo() -> None:
    config = cargar_config()
    config["modo"] = "DEMO"  # el ejemplo siempre simula, sea cual sea el modo activo
    ceo = CEOIA(config, Libro())  # libro en memoria: no toca ningún archivo
    ingresos = [
        Ingreso("TAQ-001", "60000.00", "demo", "2026-11-08", "Taquilla"),
        Ingreso("TAQ-002", "50000.00", "demo", "2026-11-15", "Patrocinio"),
        Ingreso("TAQ-002", "50000.00", "demo", "2026-11-15", "Captura repetida"),
        Ingreso("", "9000.00", "demo", "2026-11-20", "Efectivo sin recibo"),
        Ingreso("PROY-1", "25000.00", "demo", "2026-11-22", "Proyección", estimado=True),
    ]
    print(json.dumps(asdict(ceo.cerrar_periodo("lienzo-demo", "2026-11", ingresos)),
                     ensure_ascii=False, indent=2))


def verificar_conexion() -> None:
    """Solo lee: confirma que la clave sirve y que las tablas ya están instaladas."""
    for tabla in RepositorioCharros.desde_entorno().verificar():
        print(f"OK: {tabla}")


if __name__ == "__main__":
    if "--verificar" in sys.argv:
        try:
            verificar_conexion()
        except ErrorSupabase as e:
            sys.exit(f"Falló la conexión: {e}")
    else:
        print(f"Modo activo: {leer_modo()}. Ejemplo simulado, no se guarda nada:\n")
        _ejemplo()
