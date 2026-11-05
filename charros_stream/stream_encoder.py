"""
El motor de transmisión: mantiene un solo ffmpeg enviando video y audio sin interrupciones.

La imagen no se detiene nunca. El audio entra por una tubería en tiempo real: si Citlali habla se
envía su voz, y si no, silencio. Por eso una falla de Claude o de ElevenLabs no corta la señal.

Variables de entorno:
    CHARROS_STREAM_RTMP_URL   destino completo (rtmp:// o rtmps://). Incluye la clave de transmisión:
                              trátala como una contraseña. Nunca aparece en los logs.
    CHARROS_STREAM_VISUAL     archivo de video o imagen del avatar. Sin él, se envía un fondo liso.

El video del avatar se repite en bucle: no mueve la boca al hablar. Para sincronía labial hace falta
un motor de avatar que entregue el video ya animado.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from collections import deque
from pathlib import Path
from urllib.parse import urlsplit

from voice_tts import BYTES_POR_SEGUNDO, CANALES, FRECUENCIA

log = logging.getLogger("transmision")
BLOQUE_SEG = 0.05
BLOQUE = int(BYTES_POR_SEGUNDO * BLOQUE_SEG) // 4 * 4
SILENCIO = bytes(BLOQUE)
ESPERA_MAX = 30
IMAGENES = {".png", ".jpg", ".jpeg", ".webp"}


def ocultar_destino(destino: str) -> str:
    partes = urlsplit(destino)
    return f"{partes.scheme}://{partes.hostname}" if partes.scheme else "archivo local"


def comando_ffmpeg(destino: str, visual: str | None) -> list[str]:
    if not visual:
        video = ["-re", "-f", "lavfi", "-i", "color=c=0x15100c:s=1280x720:r=30"]
    elif Path(visual).suffix.lower() in IMAGENES:
        video = ["-re", "-loop", "1", "-framerate", "30", "-i", visual]
    else:
        video = ["-re", "-stream_loop", "-1", "-i", visual]
    return [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-nostdin", *video,
        "-thread_queue_size", "1024", "-f", "s16le", "-ar", str(FRECUENCIA), "-ac", str(CANALES), "-i", "pipe:0",
        "-map", "0:v:0", "-map", "1:a:0",
        "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-r", "30", "-g", "60",
        "-b:v", "2500k", "-maxrate", "2500k", "-bufsize", "5000k",
        "-c:a", "aac", "-b:a", "128k", "-ar", str(FRECUENCIA), "-f", "flv", destino,
    ]


class Transmision:
    def __init__(self, destino: str, visual: str | None = None):
        self.destino, self.visual = destino, visual
        self.cola: deque[tuple[bytearray, asyncio.Future]] = deque()
        self.reinicios = 0

    async def hablar(self, pcm: bytes) -> None:
        """Pone el audio al aire y regresa cuando terminó de sonar."""
        terminado = asyncio.get_running_loop().create_future()
        self.cola.append((bytearray(pcm), terminado))
        await terminado

    def siguiente_bloque(self) -> bytes:
        while self.cola:
            audio, terminado = self.cola[0]
            if audio:
                bloque = bytes(audio[:BLOQUE]).ljust(BLOQUE, b"\0")
                del audio[:BLOQUE]
                return bloque
            self.cola.popleft()
            if not terminado.done():
                terminado.set_result(None)
        return SILENCIO

    async def correr(self) -> None:
        """Mantiene ffmpeg vivo. Si muere, se reinicia con espera creciente y la voz sigue en cola."""
        espera = 1
        while True:
            inicio = time.monotonic()
            await self.sesion()
            if time.monotonic() - inicio > 60:
                espera = 1  # estuvo estable: el siguiente reintento es inmediato
            self.reinicios += 1
            log.warning("Se cortó la señal hacia %s. Reintento en %s s", ocultar_destino(self.destino), espera)
            await asyncio.sleep(espera)
            espera = min(espera * 2, ESPERA_MAX)

    async def sesion(self) -> None:
        proceso = await asyncio.create_subprocess_exec(
            *comando_ffmpeg(self.destino, self.visual), stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)
        log.info("Transmitiendo hacia %s", ocultar_destino(self.destino))
        errores = asyncio.create_task(self.leer_errores(proceso))
        objetivo = time.monotonic()
        try:
            while proceso.returncode is None:
                objetivo += BLOQUE_SEG
                pausa = objetivo - time.monotonic()
                if pausa > 0:
                    await asyncio.sleep(pausa)
                elif pausa < -1:
                    objetivo = time.monotonic()  # tras un atraso grande no se intenta recuperar de golpe
                proceso.stdin.write(self.siguiente_bloque())
                await asyncio.wait_for(proceso.stdin.drain(), 10)
        except (BrokenPipeError, ConnectionResetError, asyncio.TimeoutError):
            pass
        finally:
            errores.cancel()
            if proceso.returncode is None:
                proceso.stdin.close()
                proceso.terminate()
                try:
                    await asyncio.wait_for(proceso.wait(), 3)
                except asyncio.TimeoutError:
                    proceso.kill()
                    await proceso.wait()

    async def leer_errores(self, proceso) -> None:
        async for linea in proceso.stderr:
            texto = linea.decode(errors="replace").strip().replace(self.destino, ocultar_destino(self.destino))
            log.warning("ffmpeg: %s", texto[:200])


def destino_real() -> str:
    destino = os.getenv("CHARROS_STREAM_RTMP_URL", "")
    if not destino.startswith(("rtmp://", "rtmps://")):
        raise ValueError("CHARROS_STREAM_RTMP_URL debe empezar con rtmp:// o rtmps://")
    return destino
