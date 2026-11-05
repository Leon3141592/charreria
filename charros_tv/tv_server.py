#!/usr/bin/env python3
"""
Charros TV: servidor de la televisora automatizada del lienzo.

Esqueleto funcional, sin dependencias: basta con Python 3.10 o superior.

    python3 tv_server.py      y abre http://127.0.0.1:8765

Rutas:
    GET  /                 panel (index.html)
    GET  /api/estado       modo y estado de las cámaras
    POST /api/modo         cambia DEMO/REAL; solo desde esta misma computadora
    WS   /ws/panel         el panel recibe estado y cuadros de video
    WS   /ws/camara/<id>   un puente entrega cuadros JPEG de una cámara

Cómo llega el video de una OBSBOT:
    Las cámaras no hablan WebSocket. Entregan video por USB, RTSP, RTMP o NDI, según
    el modelo. Hace falta un puente (por ejemplo ffmpeg más un script) que convierta esa
    señal en cuadros JPEG y los envíe a /ws/camara/<id>. El puente todavía no existe.
    JPEG por WebSocket sirve para monitorear; para transmitir al público en alta calidad
    habrá que usar un servidor de medios (WebRTC o HLS).

Modos:
    DEMO  señal simulada; el servidor no acepta cámaras.
    REAL  acepta puentes con 'Authorization: Bearer <CHARROS_TV_TOKEN>'.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import json
import os
import struct
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit

BASE = Path(__file__).resolve().parent
sys.path.insert(0, str(BASE.parent / "charros_pro_matrix"))
from core_engine import ErrorMotor, cambiar_modo, cargar_config, leer_modo  # noqa: E402

GUID_WS = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"  # constante fija del protocolo (RFC 6455)
MAX_CUADRO = 2 * 1024 * 1024   # tamaño máximo de un JPEG entrante
MAX_PANEL = 4096               # el panel casi no envía datos
SENAL_VIGENTE = 3.0            # segundos sin cuadros para declarar "sin señal"
LOOPBACK = {"127.0.0.1", "::1", "::ffff:127.0.0.1"}

OP_TEXTO, OP_BINARIO, OP_CIERRE, OP_PING, OP_PONG = 0x1, 0x2, 0x8, 0x9, 0xA


# --------------------------------------------------------------------------- WebSocket mínimo

def aceptar_ws(clave: str) -> str:
    return base64.b64encode(hashlib.sha1((clave + GUID_WS).encode()).digest()).decode()


def marco_ws(opcode: int, datos: bytes) -> bytes:
    """Arma un marco del servidor al cliente (estos no llevan máscara)."""
    n = len(datos)
    if n < 126:
        cabecera = struct.pack("!BB", 0x80 | opcode, n)
    elif n < 65536:
        cabecera = struct.pack("!BBH", 0x80 | opcode, 126, n)
    else:
        cabecera = struct.pack("!BBQ", 0x80 | opcode, 127, n)
    return cabecera + datos


async def leer_marco(lector: asyncio.StreamReader, limite: int) -> tuple[int, bytes]:
    """Lee un marco del cliente. El protocolo exige máscara; no se admite fragmentación."""
    b0, b1 = await lector.readexactly(2)
    opcode, largo = b0 & 0x0F, b1 & 0x7F
    if not b0 & 0x80 or opcode == 0 or not b1 & 0x80:
        raise ConnectionError("Marco fragmentado o sin máscara")
    if largo == 126:
        (largo,) = struct.unpack("!H", await lector.readexactly(2))
    elif largo == 127:
        (largo,) = struct.unpack("!Q", await lector.readexactly(8))
    if largo > limite:
        raise ConnectionError("Marco demasiado grande")
    mascara = await lector.readexactly(4)
    datos = await lector.readexactly(largo)
    # XOR de todo el mensaje de una vez: mucho más rápido que byte por byte en Python.
    repetida = (mascara * (largo // 4 + 1))[:largo]
    claro = int.from_bytes(datos, "big") ^ int.from_bytes(repetida, "big")
    return opcode, claro.to_bytes(largo, "big")


# --------------------------------------------------------------------------- servidor

class Panel:
    """Un navegador conectado. Si se atrasa se le tiran cuadros, para no frenar a los demás."""

    def __init__(self, escritor: asyncio.StreamWriter):
        self.escritor = escritor
        self.cola: asyncio.Queue[bytes] = asyncio.Queue(maxsize=8)

    def enviar(self, marco: bytes) -> None:
        try:
            self.cola.put_nowait(marco)
        except asyncio.QueueFull:
            pass

    async def emitir(self) -> None:
        while True:
            self.escritor.write(await self.cola.get())
            await self.escritor.drain()


class ServidorTV:
    def __init__(self) -> None:
        self.config = cargar_config()
        self.host = self.config["tv"]["host"]
        self.puerto = self.config["tv"]["puerto"]
        self.camaras = {c["id"]: c["nombre"] for c in self.config["tv"]["camaras"]}
        self.ultima_senal: dict[str, float] = {}
        self.puentes: dict[str, asyncio.StreamWriter] = {}
        self.paneles: set[Panel] = set()
        self.modo = leer_modo()

    # ---- estado

    def estado(self) -> dict:
        ahora = time.monotonic()

        def senal(cam: str) -> str:
            if self.modo == "DEMO":
                return "simulada"
            vigente = ahora - self.ultima_senal.get(cam, -SENAL_VIGENTE) < SENAL_VIGENTE
            return "en_vivo" if vigente else "sin_senal"

        return {
            "tipo": "estado",
            "modo": self.modo,
            "camaras": [{"id": c, "nombre": n, "senal": senal(c)} for c, n in self.camaras.items()],
        }

    def difundir_estado(self) -> None:
        marco = marco_ws(OP_TEXTO, json.dumps(self.estado(), ensure_ascii=False).encode())
        for panel in self.paneles:
            panel.enviar(marco)

    def sincronizar_modo(self) -> None:
        """config.json manda. Fuera de REAL no debe quedar ningún puente conectado."""
        self.modo = leer_modo()
        if self.modo != "REAL":
            for puente in list(self.puentes.values()):
                puente.close()
            self.puentes.clear()
            self.ultima_senal.clear()

    async def latido(self) -> None:
        while True:
            await asyncio.sleep(1)
            try:
                self.sincronizar_modo()
            except (ErrorMotor, OSError, ValueError, KeyError) as e:
                print(f"No se pudo leer la configuración: {e}", file=sys.stderr)
            self.difundir_estado()

    # ---- HTTP

    async def atender(self, lector: asyncio.StreamReader, escritor: asyncio.StreamWriter) -> None:
        try:
            crudo = await asyncio.wait_for(lector.readuntil(b"\r\n\r\n"), 10)
            linea, *resto = crudo.decode("latin-1").split("\r\n")
            metodo, destino, _ = linea.split(" ", 2)
            cabeceras = {}
            for h in resto:
                if ":" in h:
                    k, v = h.split(":", 1)
                    cabeceras[k.strip().lower()] = v.strip()
            ruta = urlsplit(destino).path

            if cabeceras.get("upgrade", "").lower() == "websocket" and metodo == "GET":
                await self.abrir_ws(ruta, cabeceras, lector, escritor)
            elif metodo == "GET" and ruta == "/":
                html = (BASE / "index.html").read_bytes()
                await self.responder(escritor, 200, html, "text/html; charset=utf-8")
            elif metodo == "GET" and ruta == "/api/estado":
                await self.responder_json(escritor, 200, self.estado())
            elif metodo == "POST" and ruta == "/api/modo":
                await self.api_modo(cabeceras, lector, escritor)
            else:
                await self.responder_json(escritor, 404, {"error": "No encontrado"})
        except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError,
                ConnectionError, ValueError):
            pass
        finally:
            escritor.close()

    async def responder(self, escritor, codigo: int, cuerpo: bytes, tipo: str) -> None:
        escritor.write(
            f"HTTP/1.1 {codigo} OK\r\nContent-Type: {tipo}\r\nContent-Length: {len(cuerpo)}\r\n"
            "Cache-Control: no-store\r\nConnection: close\r\n\r\n".encode() + cuerpo)
        await escritor.drain()

    async def responder_json(self, escritor, codigo: int, datos: dict) -> None:
        cuerpo = json.dumps(datos, ensure_ascii=False).encode()
        await self.responder(escritor, codigo, cuerpo, "application/json; charset=utf-8")

    def origen_valido(self, cabeceras: dict) -> bool:
        """Evita que una página ajena use el navegador del operador para hablarle al servidor."""
        origen = cabeceras.get("origin")
        return origen is None or urlsplit(origen).netloc == cabeceras.get("host")

    async def api_modo(self, cabeceras, lector, escritor) -> None:
        ip = escritor.get_extra_info("peername")[0]
        anfitrion = urlsplit("//" + cabeceras.get("host", "")).hostname
        if ip not in LOOPBACK or anfitrion not in ("localhost", "127.0.0.1", "::1") \
                or not self.origen_valido(cabeceras):
            await self.responder_json(escritor, 403, {"error": "Solo desde esta computadora"})
            return
        largo = int(cabeceras.get("content-length", 0))
        if not 0 < largo <= 256:
            await self.responder_json(escritor, 400, {"error": "Solicitud inválida"})
            return
        try:
            cuerpo = json.loads(await lector.readexactly(largo))
            cambiar_modo(cuerpo.get("modo", ""))
        except ErrorMotor as e:
            await self.responder_json(escritor, 409, {"error": str(e)})
            return
        except (json.JSONDecodeError, AttributeError):
            await self.responder_json(escritor, 400, {"error": "Solicitud inválida"})
            return
        self.sincronizar_modo()
        self.difundir_estado()
        await self.responder_json(escritor, 200, self.estado())

    # ---- WebSocket

    async def abrir_ws(self, ruta, cabeceras, lector, escritor) -> None:
        clave = cabeceras.get("sec-websocket-key")
        partes = ruta.strip("/").split("/")
        if not clave:
            await self.responder_json(escritor, 400, {"error": "Falta la clave WebSocket"})
        elif ruta == "/ws/panel":
            if not self.origen_valido(cabeceras):
                await self.responder_json(escritor, 403, {"error": "Origen no permitido"})
                return
            await self.saludar_ws(escritor, clave)
            await self.sesion_panel(lector, escritor)
        elif len(partes) == 3 and partes[:2] == ["ws", "camara"] and partes[2] in self.camaras:
            motivo = self.rechazo_puente(cabeceras)
            if motivo:
                await self.responder_json(escritor, motivo[0], {"error": motivo[1]})
                return
            await self.saludar_ws(escritor, clave)
            await self.sesion_puente(partes[2], lector, escritor)
        else:
            await self.responder_json(escritor, 404, {"error": "Canal desconocido"})

    def rechazo_puente(self, cabeceras) -> tuple[int, str] | None:
        if self.modo != "REAL":
            return 409, "En DEMO no se aceptan cámaras"
        token = os.environ.get("CHARROS_TV_TOKEN", "")
        recibido = cabeceras.get("authorization", "").removeprefix("Bearer ").strip()
        if not token or not hmac.compare_digest(token.encode(), recibido.encode()):
            return 401, "Token inválido"
        return None

    async def saludar_ws(self, escritor, clave: str) -> None:
        escritor.write(
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {aceptar_ws(clave)}\r\n\r\n".encode())
        await escritor.drain()

    async def sesion_panel(self, lector, escritor) -> None:
        panel = Panel(escritor)
        self.paneles.add(panel)
        emisor = asyncio.create_task(panel.emitir())
        panel.enviar(marco_ws(OP_TEXTO, json.dumps(self.estado(), ensure_ascii=False).encode()))
        try:
            while True:
                opcode, datos = await leer_marco(lector, MAX_PANEL)
                if opcode == OP_CIERRE:
                    break
                if opcode == OP_PING:
                    panel.enviar(marco_ws(OP_PONG, datos))
        finally:
            self.paneles.discard(panel)
            emisor.cancel()

    async def sesion_puente(self, camara: str, lector, escritor) -> None:
        """Recibe JPEG y los reenvía al panel como: [largo del id][id][JPEG]."""
        anterior = self.puentes.get(camara)
        if anterior:
            anterior.close()  # gana la conexión más reciente
        self.puentes[camara] = escritor
        prefijo = bytes([len(camara)]) + camara.encode()
        try:
            while True:
                opcode, datos = await leer_marco(lector, MAX_CUADRO)
                if opcode == OP_CIERRE:
                    break
                if opcode == OP_PING:
                    escritor.write(marco_ws(OP_PONG, datos))
                elif opcode == OP_BINARIO and self.modo == "REAL":
                    self.ultima_senal[camara] = time.monotonic()
                    marco = marco_ws(OP_BINARIO, prefijo + datos)
                    for panel in self.paneles:
                        panel.enviar(marco)
        finally:
            if self.puentes.get(camara) is escritor:
                del self.puentes[camara]

    # ---- arranque

    async def correr(self) -> None:
        servidor = await asyncio.start_server(self.atender, self.host, self.puerto, limit=65536)
        latido = asyncio.create_task(self.latido())
        print(f"Charros TV en http://{self.host}:{self.puerto} (modo {self.modo})")
        async with servidor:
            try:
                await servidor.serve_forever()
            finally:
                latido.cancel()


if __name__ == "__main__":
    try:
        asyncio.run(ServidorTV().correr())
    except KeyboardInterrupt:
        print("\nCharros TV detenido.")
