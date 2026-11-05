#!/usr/bin/env python3
"""
Puente de cámaras OBSBOT hacia Charros TV.

    cámara --RTSP/RTMP/USB--> ffmpeg --JPEG--> este puente --WebSocket--> tv_server.py --> panel

Necesita ffmpeg instalado y a tv_server.py corriendo en modo REAL en esta misma computadora.

Cada cámara de config.json se activa con su variable de entorno, por ejemplo CHARROS_CAM_CAM1_URL
para "cam1". Las direcciones van en el entorno porque suelen llevar usuario, contraseña o stream key.

    rtsp://usuario:clave@192.168.1.50:554/ruta   leer de la cámara (también rtsps:// y srt://)
    rtmp://servidor/live/clave                   leer de un servidor RTMP
    rtmp-escucha:1935/live/cam1                  esperar a que la cámara envíe; abre ese puerto en la red
    dispositivo:0                                cámara USB (índice en macOS, /dev/videoN en Linux)
    prueba:                                      señal de prueba generada por ffmpeg, sin cámara

Variables obligatorias: CHARROS_TV_TOKEN y al menos una CHARROS_CAM_<ID>_URL.
Opcionales: CHARROS_CAM_FPS (10), CHARROS_CAM_ANCHO (1280) y CHARROS_CAM_CALIDAD (6; de 2 a 31, menos es mejor).

Uso:  python3 obsbot_bridge.py        (Ctrl+C para detener)

Seguridad: los logs ocultan usuario, contraseña, ruta y stream key, y nunca muestran el token.
La dirección sí la ve quien liste procesos en esta computadora, porque ffmpeg la recibe como argumento.

Este puente sirve para monitorear en el panel, no para transmitir al público: envía JPEG de calidad
reducida, sin audio. La salida al público necesita un servidor de medios (WebRTC o HLS).
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import logging
import os
import re
import shutil
import signal
import struct
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit

BASE = Path(__file__).resolve().parent
sys.path.insert(0, str(BASE.parent / "charros_pro_matrix"))
from core_engine import ErrorMotor, cargar_config  # noqa: E402

GUID_WS = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"  # constante fija del protocolo (RFC 6455)
MAX_CUADRO = 2 * 1024 * 1024    # debe coincidir con tv_server.py
SIN_SENAL_SEG = 10              # sin datos de ffmpeg durante este tiempo, se reinicia la captura
ESPERA_MIN, ESPERA_MAX = 1, 30  # reintentos con espera creciente, en segundos
ESPERA_DEMO = 5                 # revisión mientras tv_server.py está en DEMO
REPORTE_SEG = 10
OP_BINARIO, OP_CIERRE = 0x2, 0x8
LOOPBACK = ("127.0.0.1", "localhost", "::1")


class ErrorPuente(Exception):
    """Error de configuración con un mensaje que se le puede mostrar al usuario."""


# --------------------------------------------------------------------------- utilidades

def ocultar_fuente(fuente: str) -> str:
    """Deja solo protocolo y servidor: usuario, contraseña, ruta y stream key no llegan al log."""
    if "://" not in fuente:
        return fuente
    partes = urlsplit(fuente)
    return f"{partes.scheme}://{partes.hostname or '?'}"


def limpiar_log(linea: str, fuente: str) -> str:
    """ffmpeg a veces repite la dirección en sus errores."""
    linea = linea.replace(fuente, ocultar_fuente(fuente))
    return re.sub(r"\b([a-z][a-z0-9+.-]*)://\S+", r"\1://***", linea)


def comando_ffmpeg(fuente: str, fps: int, ancho: int, calidad: int) -> list[str]:
    baja_latencia = ["-fflags", "nobuffer", "-flags", "low_delay"]
    protocolo = fuente.split(":", 1)[0].lower()
    if protocolo in ("rtsp", "rtsps"):
        entrada = baja_latencia + ["-rtsp_transport", "tcp", "-timeout", "5000000", "-i", fuente]
    elif protocolo in ("rtmp", "rtmps", "srt"):
        entrada = baja_latencia + ["-i", fuente]
    elif protocolo == "rtmp-escucha":
        entrada = ["-listen", "1", "-i", "rtmp://0.0.0.0:" + fuente.split(":", 1)[1]]
    elif protocolo == "dispositivo":
        indice = fuente.split(":", 1)[1]
        if sys.platform == "darwin":
            entrada = ["-f", "avfoundation", "-framerate", "30", "-i", indice]
        else:
            entrada = ["-f", "v4l2", "-i", f"/dev/video{indice}"]
    elif protocolo == "prueba":
        entrada = ["-re", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30"]
    else:
        raise ErrorPuente(f"Fuente no reconocida: {ocultar_fuente(fuente)}")
    # Se reduce antes de enviar: los cuadros de más se descartan aquí y no viajan por la red.
    return ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", *entrada, "-an",
            "-vf", f"fps={fps},scale='min({ancho},iw)':-2", "-pix_fmt", "yuvj420p",
            "-c:v", "mjpeg", "-q:v", str(calidad), "-f", "image2pipe", "-"]


class ExtractorJPEG:
    """Separa los JPEG del flujo de ffmpeg, que llega en pedazos de cualquier tamaño."""

    def __init__(self) -> None:
        self.buffer = bytearray()

    def agregar(self, datos: bytes) -> list[bytes]:
        self.buffer += datos
        cuadros = []
        while True:
            inicio = self.buffer.find(b"\xff\xd8")
            if inicio < 0:
                del self.buffer[:-1]  # conserva un byte: el marcador pudo quedar partido
                return cuadros
            fin = self.buffer.find(b"\xff\xd9", inicio + 2)
            if fin < 0:
                del self.buffer[:inicio]
                if len(self.buffer) > MAX_CUADRO:
                    self.buffer.clear()  # cuadro imposible: mejor esperar el siguiente
                return cuadros
            cuadros.append(bytes(self.buffer[inicio:fin + 2]))
            del self.buffer[:fin + 2]


def marco_cliente(opcode: int, datos: bytes) -> bytes:
    """Arma un marco WebSocket. El protocolo exige que el cliente los enmascare."""
    n = len(datos)
    if n < 126:
        cabecera = struct.pack("!BB", 0x80 | opcode, 0x80 | n)
    elif n < 65536:
        cabecera = struct.pack("!BBH", 0x80 | opcode, 0x80 | 126, n)
    else:
        cabecera = struct.pack("!BBQ", 0x80 | opcode, 0x80 | 127, n)
    mascara = os.urandom(4)
    if not n:
        return cabecera + mascara
    repetida = (mascara * (n // 4 + 1))[:n]
    claro = int.from_bytes(datos, "big") ^ int.from_bytes(repetida, "big")
    return cabecera + mascara + claro.to_bytes(n, "big")


# --------------------------------------------------------------------------- puente

class PuenteCamara:
    """
    Dos ciclos independientes por cámara: capturar y emitir. Si uno se cae, el otro sigue.
    Entre ellos solo existe el cuadro más reciente: si la red se atrasa se pierden cuadros,
    pero el video nunca se va retrasando.
    """

    def __init__(self, camara: str, fuente: str, host: str, puerto: int, token: str,
                 fps: int, ancho: int, calidad: int):
        self.camara, self.fuente = camara, fuente
        self.host, self.puerto, self.token = host, puerto, token
        self.comando = comando_ffmpeg(fuente, fps, ancho, calidad)
        self.log = logging.getLogger(camara)
        self.cuadro: bytes | None = None
        self.hay_cuadro = asyncio.Event()
        self.senal = False
        self.conectado = False
        self.enviados = self.descartados = 0

    async def correr(self) -> None:
        self.log.info("Fuente: %s", ocultar_fuente(self.fuente))
        await asyncio.gather(self.capturar(), self.emitir(), self.reportar())

    # ---- captura

    async def capturar(self) -> None:
        espera = ESPERA_MIN
        while True:
            hubo_video = await self.sesion_ffmpeg()
            self.senal = False
            espera = ESPERA_MIN if hubo_video else min(espera * 2, ESPERA_MAX)
            self.log.warning("Sin señal. Reintento en %s s", espera)
            await asyncio.sleep(espera)

    async def sesion_ffmpeg(self) -> bool:
        proceso = await asyncio.create_subprocess_exec(
            *self.comando, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            stdin=asyncio.subprocess.DEVNULL)
        errores = asyncio.create_task(self.leer_errores(proceso))
        extractor, hubo_video = ExtractorJPEG(), False
        try:
            while True:
                try:
                    datos = await asyncio.wait_for(proceso.stdout.read(65536), SIN_SENAL_SEG)
                except asyncio.TimeoutError:
                    self.log.warning("La cámara dejó de enviar video")
                    return hubo_video
                if not datos:
                    return hubo_video
                for cuadro in extractor.agregar(datos):
                    if len(cuadro) > MAX_CUADRO:
                        self.descartados += 1
                        continue
                    if not self.senal:
                        self.log.info("Señal recibida")
                    self.senal = hubo_video = True
                    if self.hay_cuadro.is_set():
                        self.descartados += 1  # el anterior no alcanzó a salir
                    self.cuadro = cuadro
                    self.hay_cuadro.set()
        finally:
            errores.cancel()
            if proceso.returncode is None:
                proceso.kill()
            await proceso.wait()

    async def leer_errores(self, proceso) -> None:
        async for linea in proceso.stderr:
            self.log.warning("ffmpeg: %s", limpiar_log(linea.decode(errors="replace").strip(), self.fuente))

    # ---- envío

    async def emitir(self) -> None:
        espera = ESPERA_MIN
        while True:
            try:
                estado, lector, escritor = await self.conectar()
            except (OSError, asyncio.TimeoutError, asyncio.IncompleteReadError, ValueError):
                self.log.warning("tv_server.py no responde. Reintento en %s s", espera)
                await asyncio.sleep(espera)
                espera = min(espera * 2, ESPERA_MAX)
                continue

            if estado != 101:
                escritor.close()
                motivos = {401: "Token rechazado: revisa CHARROS_TV_TOKEN",
                           404: "tv_server.py no conoce esta cámara",
                           409: "tv_server.py está en DEMO: cámbialo a REAL"}
                # Cambiar a REAL es rápido, así que DEMO se revisa seguido; lo demás necesita a una persona.
                pausa = ESPERA_DEMO if estado == 409 else ESPERA_MAX
                self.log.warning("%s. Reintento en %s s", motivos.get(estado, f"Respuesta {estado}"), pausa)
                await asyncio.sleep(pausa)
                continue

            espera = ESPERA_MIN
            self.conectado = True
            self.log.info("Conectado a tv_server.py")
            try:
                await self.enviar_cuadros(lector, escritor)
            except (OSError, asyncio.TimeoutError):
                pass
            finally:
                self.conectado = False
                escritor.close()
            self.log.warning("Se perdió la conexión con tv_server.py")

    async def conectar(self):
        lector, escritor = await asyncio.wait_for(asyncio.open_connection(self.host, self.puerto), 5)
        try:
            clave = base64.b64encode(os.urandom(16)).decode()
            escritor.write(
                f"GET /ws/camara/{self.camara} HTTP/1.1\r\nHost: {self.host}:{self.puerto}\r\n"
                "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {clave}\r\nSec-WebSocket-Version: 13\r\n"
                f"Authorization: Bearer {self.token}\r\n\r\n".encode())
            await escritor.drain()
            respuesta = await asyncio.wait_for(lector.readuntil(b"\r\n\r\n"), 5)
            estado = int(respuesta.split(b" ", 2)[1])
            esperada = base64.b64encode(hashlib.sha1((clave + GUID_WS).encode()).digest())
            if estado == 101 and esperada not in respuesta:
                raise ValueError("Saludo WebSocket inválido")
        except BaseException:
            escritor.close()
            raise
        return estado, lector, escritor

    async def enviar_cuadros(self, lector, escritor) -> None:
        cerrado = asyncio.create_task(lector.read())  # el servidor no envía datos: solo se espera el cierre
        try:
            while True:
                nuevo = asyncio.create_task(self.hay_cuadro.wait())
                await asyncio.wait({cerrado, nuevo}, return_when=asyncio.FIRST_COMPLETED)
                if cerrado.done():
                    nuevo.cancel()
                    return
                self.hay_cuadro.clear()
                escritor.write(marco_cliente(OP_BINARIO, self.cuadro))
                await asyncio.wait_for(escritor.drain(), 5)
                self.enviados += 1
        finally:
            cerrado.cancel()

    # ---- estado en la terminal

    async def reportar(self) -> None:
        anterior, inicio = 0, time.monotonic()
        while True:
            await asyncio.sleep(REPORTE_SEG)
            ahora = time.monotonic()
            ritmo = (self.enviados - anterior) / (ahora - inicio)
            anterior, inicio = self.enviados, ahora
            self.log.info("señal=%s servidor=%s cuadros/s=%.1f enviados=%d descartados=%d",
                          "ok" if self.senal else "NO", "ok" if self.conectado else "NO",
                          ritmo, self.enviados, self.descartados)


# --------------------------------------------------------------------------- arranque

def entero_entorno(nombre: str, defecto: int, minimo: int, maximo: int) -> int:
    texto = os.getenv(nombre, str(defecto))
    if not texto.isdigit() or not minimo <= int(texto) <= maximo:
        raise ErrorPuente(f"{nombre} debe ser un número entre {minimo} y {maximo}")
    return int(texto)


def crear_puentes() -> list[PuenteCamara]:
    config = cargar_config()["tv"]
    if config["host"] not in LOOPBACK:
        # tv_server.py no usa TLS: fuera de esta computadora el token viajaría en texto plano.
        raise ErrorPuente("El puente solo se conecta a tv_server.py en esta misma computadora.")
    if not shutil.which("ffmpeg"):
        raise ErrorPuente("No encontré ffmpeg. En macOS se instala con: brew install ffmpeg")
    token = os.getenv("CHARROS_TV_TOKEN")
    if not token:
        raise ErrorPuente("Falta la variable CHARROS_TV_TOKEN")
    fps = entero_entorno("CHARROS_CAM_FPS", 10, 1, 30)
    ancho = entero_entorno("CHARROS_CAM_ANCHO", 1280, 160, 3840)
    calidad = entero_entorno("CHARROS_CAM_CALIDAD", 6, 2, 31)

    puentes = []
    for camara in config["camaras"]:
        fuente = os.getenv(f"CHARROS_CAM_{camara['id'].upper()}_URL")
        if fuente:
            puentes.append(PuenteCamara(camara["id"], fuente, config["host"], config["puerto"],
                                        token, fps, ancho, calidad))
    if not puentes:
        raise ErrorPuente("Ninguna cámara activa. Define por ejemplo CHARROS_CAM_CAM1_URL.")
    return puentes


async def principal() -> None:
    puentes = crear_puentes()
    tarea = asyncio.gather(*(p.correr() for p in puentes))
    # Un administrador de servicios detiene con SIGTERM: se limpia igual que con Ctrl+C.
    asyncio.get_running_loop().add_signal_handler(signal.SIGTERM, tarea.cancel)
    try:
        await tarea
    except asyncio.CancelledError:
        print("Puente detenido.")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s [%(name)s] %(message)s",
                        datefmt="%H:%M:%S")
    try:
        asyncio.run(principal())
    except (ErrorPuente, ErrorMotor) as e:
        sys.exit(str(e))
    except KeyboardInterrupt:
        print("\nPuente detenido.")
