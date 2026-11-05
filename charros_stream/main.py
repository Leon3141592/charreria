#!/usr/bin/env python3
"""
Citlali, conductora virtual de Charrería Pro: orquestador de la transmisión 24/7.

    python3 main.py                 simulación: sin APIs, sin costo y sin salir a internet
    python3 main.py --real          transmite de verdad; exige todas las variables de entorno
    python3 main.py --segundos 60   se detiene solo después de ese tiempo

Cada turno: si hay chat, responde. Si el chat lleva rato inactivo, cuenta una cápsula de historia o
de la plataforma. Cada cierto número de intervenciones avisa que es un personaje de IA.

Variables opcionales:
    CHARROS_TWITCH_CANAL             canal de Twitch cuyo chat se lee
    CHARROS_STREAM_PAUSA_SEG         silencio entre cápsulas (por defecto 90)
    CHARROS_STREAM_MAX_CARACTERES    tope diario de voz, que es lo que más cuesta (por defecto 20000)
    CHARROS_STREAM_MAX_LLAMADAS      tope diario de llamadas a Claude (por defecto 1500)

Al llegar a un tope el personaje calla hasta el día siguiente, y la imagen sigue al aire.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import signal
import sys
import time
from collections import deque
from datetime import date
from pathlib import Path

from ai_brain import AVISO_IA, Cerebro, CerebroSimulado, MensajeChat, limpiar_chat, limpiar_usuario
from ai_brain import analizar_texto, revisar_salida
from chat_source import ChatSimulado, ChatTwitch, ChatVacio
from stream_encoder import Transmision, destino_real
from voice_tts import Voz, VozSimulada

BASE = Path(__file__).resolve().parent
RUTA_DATOS = BASE / "datos"
log = logging.getLogger("agente")

MAX_POR_TURNO = 5        # mensajes que se responden juntos
EDAD_MAX_MENSAJE = 60    # un comentario más viejo ya no se contesta
PAUSA_USUARIO = 20       # segundos mínimos entre mensajes atendidos de la misma persona
AVISO_CADA = 8           # intervenciones entre un aviso de IA y el siguiente
ESPERA_MAX_FALLA = 60


def entero_entorno(nombre: str, defecto: int) -> int:
    texto = os.getenv(nombre, str(defecto))
    if not texto.isdigit() or int(texto) == 0:
        raise ValueError(f"{nombre} debe ser un número mayor a cero")
    return int(texto)


class Consumo:
    """Tope de gasto diario. Se guarda en disco para que un reinicio no lo ponga en cero."""

    def __init__(self, ruta: Path, max_caracteres: int, max_llamadas: int):
        self.ruta, self.max_caracteres, self.max_llamadas = ruta, max_caracteres, max_llamadas
        self.datos = {"dia": "", "caracteres": 0, "llamadas": 0}
        if ruta.exists():
            try:
                self.datos = json.loads(ruta.read_text())
            except ValueError:
                log.warning("Archivo de consumo dañado: se ignora")

    def _hoy(self) -> None:
        if self.datos["dia"] != date.today().isoformat():
            self.datos = {"dia": date.today().isoformat(), "caracteres": 0, "llamadas": 0}

    def disponible(self) -> bool:
        self._hoy()
        return self.datos["caracteres"] < self.max_caracteres and self.datos["llamadas"] < self.max_llamadas

    def registrar(self, caracteres: int = 0, llamadas: int = 0) -> None:
        self._hoy()
        self.datos["caracteres"] += caracteres
        self.datos["llamadas"] += llamadas
        self.ruta.parent.mkdir(parents=True, exist_ok=True)
        temporal = self.ruta.with_suffix(".tmp")
        temporal.write_text(json.dumps(self.datos))
        temporal.replace(self.ruta)


class Agente:
    def __init__(self, cerebro, voz, transmision: Transmision, chat, consumo: Consumo, pausa_seg: float):
        self.cerebro, self.voz, self.transmision, self.chat = cerebro, voz, transmision, chat
        self.consumo, self.pausa_seg = consumo, pausa_seg
        self.cola: deque[tuple[float, MensajeChat]] = deque(maxlen=50)
        self.ultimo_usuario: dict[str, float] = {}
        self.ultima_voz = time.monotonic() - pausa_seg  # la primera cápsula sale de inmediato
        self.desde_aviso = AVISO_CADA                   # abre la transmisión con el aviso de IA
        self.fallas = 0
        self.en_tope = False

    def recibir(self, mensaje: MensajeChat) -> None:
        """Filtra el chat antes de que llegue al modelo. Lo ofensivo no se contesta ni se lee."""
        ahora = time.monotonic()
        usuario, texto = limpiar_usuario(mensaje.usuario), limpiar_chat(mensaje.texto)
        if not texto or ahora - self.ultimo_usuario.get(usuario, -PAUSA_USUARIO) < PAUSA_USUARIO:
            return
        hallazgo = analizar_texto(texto, usuario)
        if hallazgo.nivel > 0:
            log.warning("Mensaje ignorado de %s: %s", usuario, ", ".join(hallazgo.categorias))
            return
        self.ultimo_usuario[usuario] = ahora
        if len(self.ultimo_usuario) > 1000:
            self.ultimo_usuario.clear()
        self.cola.append((ahora, MensajeChat(usuario, texto)))

    def tomar_mensajes(self) -> list[MensajeChat]:
        ahora, mensajes = time.monotonic(), []
        while self.cola and len(mensajes) < MAX_POR_TURNO:
            llegada, mensaje = self.cola.popleft()
            if ahora - llegada <= EDAD_MAX_MENSAJE:
                mensajes.append(mensaje)
        return mensajes

    async def decir(self, texto: str | None, tipo: str) -> None:
        if not texto:
            log.info("Turno de %s sin nada que decir", tipo)
            return
        pcm = await self.voz.sintetizar(texto)
        self.consumo.registrar(caracteres=len(texto))
        log.info("[%s] %s", tipo, texto)
        await self.transmision.hablar(pcm)
        self.ultima_voz = time.monotonic()
        self.desde_aviso = 0 if tipo == "aviso" else self.desde_aviso + 1

    async def turno(self) -> bool:
        """Hace una sola cosa. Devuelve False si no había nada que hacer."""
        if not self.consumo.disponible():
            if not self.en_tope:
                log.warning("Tope diario alcanzado: la voz se detiene y la imagen sigue al aire")
            self.en_tope = True
            self.cola.clear()
            return False
        self.en_tope = False

        if self.desde_aviso >= AVISO_CADA:
            await self.decir(revisar_salida(AVISO_IA), "aviso")
            return True
        mensajes = self.tomar_mensajes()
        if mensajes:
            self.consumo.registrar(llamadas=1)
            await self.decir(await self.cerebro.responder(mensajes), "chat")
            return True
        if time.monotonic() - self.ultima_voz >= self.pausa_seg:
            self.consumo.registrar(llamadas=1)
            await self.decir(await self.cerebro.capsula(), "capsula")
            return True
        return False

    async def ciclo(self) -> None:
        """El bucle de 24/7. Una falla cuesta un turno, nunca la transmisión."""
        while True:
            try:
                activo = await self.turno()
                self.fallas = 0
                if not activo:
                    await asyncio.sleep(0.5)
            except asyncio.CancelledError:
                raise
            except Exception as e:  # noqa: BLE001 - frontera del agente: nada puede tumbar el bucle
                self.fallas += 1
                espera = min(2 ** self.fallas, ESPERA_MAX_FALLA)
                # Solo el tipo y el mensaje: nunca se registran cabeceras ni llaves.
                log.error("Falla %d: %s: %s. Reintento en %s s", self.fallas, type(e).__name__, str(e)[:200], espera)
                await asyncio.sleep(espera)

    async def correr(self) -> None:
        await asyncio.gather(self.transmision.correr(), self.chat.correr(self.recibir), self.ciclo())


def armar(real: bool) -> Agente:
    pausa = entero_entorno("CHARROS_STREAM_PAUSA_SEG", 90 if real else 6)
    canal = os.getenv("CHARROS_TWITCH_CANAL")
    consumo = Consumo(RUTA_DATOS / f"consumo_{'real' if real else 'simulado'}.json",
                      entero_entorno("CHARROS_STREAM_MAX_CARACTERES", 20000),
                      entero_entorno("CHARROS_STREAM_MAX_LLAMADAS", 1500))
    if real:
        if not os.getenv("ANTHROPIC_API_KEY"):
            raise ValueError("Falta ANTHROPIC_API_KEY")
        return Agente(Cerebro(), Voz(), Transmision(destino_real(), os.getenv("CHARROS_STREAM_VISUAL")),
                      ChatTwitch(canal) if canal else ChatVacio(), consumo, pausa)
    RUTA_DATOS.mkdir(exist_ok=True)
    return Agente(CerebroSimulado(), VozSimulada(),
                  Transmision(str(RUTA_DATOS / "simulacion.flv"), os.getenv("CHARROS_STREAM_VISUAL")),
                  ChatSimulado(), consumo, pausa)


async def principal(opciones) -> None:
    agente = armar(opciones.real)
    tarea = asyncio.ensure_future(agente.correr())
    asyncio.get_running_loop().add_signal_handler(signal.SIGTERM, tarea.cancel)
    try:
        await asyncio.wait_for(tarea, opciones.segundos)
    except (asyncio.CancelledError, asyncio.TimeoutError):
        log.info("Transmisión detenida")


if __name__ == "__main__":
    analizador = argparse.ArgumentParser(description="Transmisión de Citlali")
    analizador.add_argument("--real", action="store_true", help="usa las APIs y transmite de verdad")
    analizador.add_argument("--segundos", type=float, default=None, help="se detiene después de este tiempo")
    opciones = analizador.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s [%(name)s] %(message)s",
                        datefmt="%H:%M:%S")
    try:
        asyncio.run(principal(opciones))
    except KeyboardInterrupt:
        print("\nTransmisión detenida.")
    except (ValueError, Exception) as e:  # noqa: BLE001 - error de arranque, con mensaje legible
        sys.exit(f"No se pudo iniciar: {e}")
