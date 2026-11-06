#!/usr/bin/env bash
# Arma desde cero la copia LOCAL de prueba de MongoDB:
#   1) datos base del equipo, 2) historial de demostración del fork (seedShowcase),
#   3) casos válidos y sucios para probar la migración.
# Variables: FORK_BACKEND, DB_URI (local), CREDENCIALES_PRUEBA y CASOS_PRUEBA (fuera del repo).
set -euo pipefail
cd "$(dirname "$0")"
node crear_base.mjs --reiniciar
( cd "$FORK_BACKEND" && node scripts/seedShowcase.js | tail -n 3 )
node insertar_casos.mjs
