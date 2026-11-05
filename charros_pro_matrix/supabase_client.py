"""
Cliente mínimo de Supabase (su API REST), sin dependencias externas.

Usa la clave secreta del proyecto (service_role o sb_secret_...), que se salta las políticas de la
base. Por eso solo puede vivir en una variable de entorno del servidor: nunca en config.json, en
GitHub ni en una página web. La clave pública anon de la app no sirve aquí.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from urllib.parse import urlencode, urlsplit


class ErrorSupabase(Exception):
    """Falló la comunicación o la base rechazó la operación."""


class ErrorDuplicado(ErrorSupabase):
    """Ya existe un registro con esa clave."""


class ClienteSupabase:
    def __init__(self, url: str, clave: str, espera_seg: int = 15):
        partes = urlsplit(url)
        if partes.scheme != "https" and partes.hostname not in ("localhost", "127.0.0.1"):
            raise ErrorSupabase("La dirección de Supabase debe empezar con https://")
        if clave.startswith("sb_publishable_"):
            raise ErrorSupabase("Esa es la clave pública. Aquí va la clave secreta del proyecto.")
        self.base = url.rstrip("/") + "/rest/v1/"
        self.clave = clave
        self.espera = espera_seg

    @classmethod
    def desde_entorno(cls) -> "ClienteSupabase":
        url = os.environ.get("CHARROS_SUPABASE_URL")
        clave = os.environ.get("CHARROS_SUPABASE_KEY")
        if not url or not clave:
            raise ErrorSupabase("Faltan CHARROS_SUPABASE_URL o CHARROS_SUPABASE_KEY.")
        return cls(url, clave)

    def _pedir(self, metodo: str, ruta: str, cuerpo: dict | None = None) -> list:
        cabeceras = {"apikey": self.clave, "Content-Type": "application/json",
                     "Prefer": "return=minimal"}
        if not self.clave.startswith("sb_"):  # las claves JWT antiguas también van aquí
            cabeceras["Authorization"] = f"Bearer {self.clave}"
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
            if detalle.get("code") == "PGRST205":
                mensaje = "Falta la tabla: corre actualizacion_matriz.sql en Supabase."
            raise ErrorSupabase(mensaje) from None
        except (urllib.error.URLError, TimeoutError, ValueError) as e:
            raise ErrorSupabase(f"No se pudo hablar con Supabase: {e}") from None

    def insertar(self, tabla: str, fila: dict) -> None:
        self._pedir("POST", tabla, fila)

    def leer(self, tabla: str, filtros: dict[str, str]) -> list[dict]:
        """`filtros` usa la sintaxis de la API: {'select': 'id', 'periodo': 'eq.2026-11'}."""
        return self._pedir("GET", f"{tabla}?{urlencode(filtros)}")
