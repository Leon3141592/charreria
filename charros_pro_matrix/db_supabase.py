"""
Capa de persistencia de Charros Pro sobre Supabase, sin dependencias externas.

Credenciales, siempre desde variables de entorno:
    CHARROS_SUPABASE_URL   dirección del proyecto
    CHARROS_SUPABASE_KEY   clave secreta del proyecto (service_role o sb_secret_...)

Esa clave se salta las políticas de la base. Solo puede vivir en el entorno del servidor: nunca en
config.json, en GitHub, en una página web ni en un log. Este módulo no la escribe en ningún mensaje.

Quién escribe qué:
    matriz_liquidaciones, matriz_transacciones   solo mediante registrar_cierre(), todo o nada
    matriz_lienzo_estado                         este módulo
    sombra_hallazgos                             este módulo
    lienzos, tcg_cards, horses, stock, scores    los escribe la app; aquí solo se leen
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from urllib.parse import urlencode, urlsplit

TAMANO_PAGINA = 1000  # la API de Supabase no entrega más filas por petición
ESTADOS_LIENZO = ("activo", "en_vivo", "mantenimiento", "inactivo")


class ErrorSupabase(Exception):
    """Falló la comunicación o la base rechazó la operación."""


class ErrorDuplicado(ErrorSupabase):
    """Ya existe un registro con esa clave."""


class ClienteSupabase:
    """Cliente HTTP mínimo para la API REST de Supabase."""

    def __init__(self, url: str, clave: str, espera_seg: int = 15):
        partes = urlsplit(url)
        if partes.scheme != "https" and partes.hostname not in ("localhost", "127.0.0.1"):
            raise ErrorSupabase("La dirección de Supabase debe empezar con https://")
        if clave.startswith("sb_publishable_"):
            raise ErrorSupabase("Esa es la clave pública. Aquí va la clave secreta del proyecto.")
        self.base = url.rstrip("/") + "/rest/v1/"
        self._clave = clave
        self.espera = espera_seg

    def __repr__(self) -> str:  # un print() o un log del objeto no debe mostrar la clave
        return f"ClienteSupabase({self.base!r})"

    @classmethod
    def desde_entorno(cls) -> "ClienteSupabase":
        url = os.getenv("CHARROS_SUPABASE_URL")
        clave = os.getenv("CHARROS_SUPABASE_KEY")
        if not url or not clave:
            raise ErrorSupabase("Faltan CHARROS_SUPABASE_URL o CHARROS_SUPABASE_KEY.")
        return cls(url, clave)

    def _pedir(self, metodo: str, ruta: str, cuerpo: dict | None = None,
               prefer: str = "return=minimal") -> list:
        cabeceras = {"apikey": self._clave, "Content-Type": "application/json", "Prefer": prefer}
        if not self._clave.startswith("sb_"):  # las claves JWT antiguas también van aquí
            cabeceras["Authorization"] = f"Bearer {self._clave}"
        datos = None if cuerpo is None else json.dumps(cuerpo, ensure_ascii=False).encode()
        peticion = urllib.request.Request(self.base + ruta, data=datos, headers=cabeceras, method=metodo)
        try:
            with urllib.request.urlopen(peticion, timeout=self.espera) as r:
                texto = r.read()
                return json.loads(texto) if texto else []
        except urllib.error.HTTPError as e:
            try:
                detalle = json.loads(e.read())
            except ValueError:
                detalle = {}
            mensaje = detalle.get("message") or f"Error HTTP {e.code}"
            if detalle.get("code") == "23505":
                raise ErrorDuplicado(mensaje) from None
            if detalle.get("code") in ("PGRST202", "PGRST205"):
                mensaje = "Falta instalar la base: corre actualizacion_matriz.sql en Supabase."
            raise ErrorSupabase(mensaje) from None
        except (urllib.error.URLError, TimeoutError, ValueError) as e:
            raise ErrorSupabase(f"No se pudo hablar con Supabase: {e}") from None

    def insertar(self, tabla: str, fila: dict) -> None:
        self._pedir("POST", tabla, fila)

    def guardar(self, tabla: str, fila: dict, clave: str) -> None:
        """Crea la fila o actualiza solo las columnas enviadas si `clave` ya existe."""
        self._pedir("POST", f"{tabla}?{urlencode({'on_conflict': clave})}", fila,
                    "resolution=merge-duplicates,return=minimal")

    def llamar(self, funcion: str, parametros: dict) -> None:
        self._pedir("POST", f"rpc/{funcion}", parametros)

    def leer(self, tabla: str, filtros: dict[str, str]) -> list[dict]:
        """`filtros` usa la sintaxis de la API: {'select': 'id', 'periodo': 'eq.2026-11'}."""
        return self._pedir("GET", f"{tabla}?{urlencode(filtros)}")

    def leer_todo(self, tabla: str, filtros: dict[str, str]) -> list[dict]:
        """Recorre todas las páginas, con orden fijo para no repetir ni saltar filas."""
        filas: list[dict] = []
        while True:
            pagina = self.leer(tabla, {**filtros, "order": "id.asc",
                                       "limit": str(TAMANO_PAGINA), "offset": str(len(filas))})
            filas += pagina
            if len(pagina) < TAMANO_PAGINA:
                return filas


class RepositorioCharros:
    """Las operaciones de negocio. Ningún otro módulo debe armar consultas por su cuenta."""

    def __init__(self, cliente: ClienteSupabase):
        self.cliente = cliente

    @classmethod
    def desde_entorno(cls) -> "RepositorioCharros":
        return cls(ClienteSupabase.desde_entorno())

    def verificar(self) -> list[str]:
        """Solo lee: confirma que la clave sirve y que las tablas ya están instaladas."""
        tablas = {"matriz_liquidaciones": "id", "matriz_transacciones": "id",
                  "matriz_lienzo_estado": "lienzo_id", "sombra_hallazgos": "id"}
        for tabla, columna in tablas.items():
            self.cliente.leer(tabla, {"select": columna, "limit": "1"})
        return list(tablas)

    # ---- cierres financieros y transacciones medibles

    def cierre_existe(self, lienzo_id: str, periodo: str) -> bool:
        return bool(self.cliente.leer("matriz_liquidaciones", {
            "select": "id", "lienzo_id": f"eq.{lienzo_id}", "periodo": f"eq.{periodo}", "limit": "1"}))

    def registrar_cierre(self, liquidacion: dict, transacciones: list[dict]) -> None:
        """
        Guarda el cierre mensual y sus transacciones medibles en una sola operación de la base:
        o queda todo o no queda nada. Si se corta la red, reintentar es seguro porque no puede duplicar.
        """
        self.cliente.llamar("registrar_cierre", {"p_liquidacion": liquidacion,
                                                 "p_transacciones": transacciones})

    def leer_cierres(self, lienzo_id: str) -> list[dict]:
        return self.cliente.leer_todo("matriz_liquidaciones", {"lienzo_id": f"eq.{lienzo_id}"})

    def leer_transacciones(self, lienzo_id: str, periodo: str) -> list[dict]:
        return self.cliente.leer_todo("matriz_transacciones", {
            "lienzo_id": f"eq.{lienzo_id}", "periodo": f"eq.{periodo}"})

    # ---- estado de los lienzos

    def guardar_estado_lienzo(self, lienzo_id: str, estado: str, datos: dict | None = None) -> None:
        """Estado operativo. No toca `lienzos.data.status`, que es la aprobación de la app."""
        if estado not in ESTADOS_LIENZO:
            raise ErrorSupabase(f"Estado de lienzo desconocido: {estado}")
        self.cliente.guardar("matriz_lienzo_estado", {
            "lienzo_id": lienzo_id, "estado": estado, "data": datos or {}}, "lienzo_id")

    def leer_estado_lienzo(self, lienzo_id: str) -> dict | None:
        filas = self.cliente.leer("matriz_lienzo_estado", {"lienzo_id": f"eq.{lienzo_id}", "limit": "1"})
        return filas[0] if filas else None

    # ---- Sombra

    def guardar_hallazgo(self, nivel: int, origen: str, tipo: str, datos: dict) -> None:
        self.cliente.insertar("sombra_hallazgos", {
            "nivel": nivel, "origen": origen, "tipo": tipo, "data": datos})

    # ---- datos de la app (solo lectura)

    def leer_datos(self, tabla: str) -> list[dict]:
        """Devuelve el contenido de una tabla de la app, sin los registros borrados."""
        if tabla not in ("tcg_cards", "horses", "stock", "scores", "horse_rides", "events", "lienzos"):
            raise ErrorSupabase(f"Tabla no permitida: {tabla}")
        filas = self.cliente.leer_todo(tabla, {"select": "id,data"})
        return [f["data"] for f in filas if not f["data"].get("deleted")]
