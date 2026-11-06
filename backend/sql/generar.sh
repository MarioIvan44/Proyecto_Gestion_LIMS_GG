#!/usr/bin/env bash
#
# Genera pgAdminBase.sql: la estructura completa de la base, sin datos, desde las migraciones
# de Django. Sirve para revisar el esquema o cargarlo en pgAdmin 4 en una base vacía.
#
# OJO: este archivo NO venía en el repositorio; se escribió el 6-nov-2026 porque se ocupaba y
# porque hacía falta corregir el SET transaction_timeout. Si aparece el generar.sh original,
# comparar los dos y quedarse con uno solo.
#
# CUIDADO, el archivo que genera es PARCIAL mientras falten apps. Solo sale lo que exista como
# migración de Django. Desde el 6-nov-2026 el repositorio tiene nucleo, rrhh, finanzas, lectura,
# migracion (estas cuatro, traídas de Proyecto2-Geotecnia) y lab; FALTA `gestion` (Gestión GG),
# que todavía solo existe en base_total_jupaca.sql. Por eso, si ya había un pgAdminBase.sql, este
# script lo guarda como .anterior antes de escribir, y al final avisa qué apps entraron. No
# sustituir el archivo bueno con uno parcial.
#
# Cómo funciona: crea una base temporal, le corre todas las migraciones, le saca el esquema con
# pg_dump y la borra. Así lo generado siempre coincide con las migraciones y nunca toca la base
# real. El esquema lab queda incluido, porque lo crea la migración lab/0001_initial.
#
# Uso:
#   cd backend && ./sql/generar.sh                       # escribe sql/pgAdminBase.sql
#   cd backend && ./sql/generar.sh /ruta/otro_nombre.sql
#
# Necesita: el entorno virtual activado (o la variable PYTHON apuntando al intérprete), psql,
# pg_dump y permiso para crear bases en el servidor. La conexión se toma de las variables
# PGHOST/PGPORT/PGUSER/PGPASSWORD, o de PG* por defecto (localhost:5432).

set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND="$(dirname "$AQUI")"
SALIDA="${1:-$AQUI/pgAdminBase.sql}"
PYTHON="${PYTHON:-python}"

# Base temporal con un nombre que no choque si alguien corre el script dos veces a la vez.
BASE_TEMPORAL="jupaca_esquema_$$"

limpiar() {
    psql -d postgres -qc "DROP DATABASE IF EXISTS \"$BASE_TEMPORAL\"" >/dev/null 2>&1 || true
}
trap limpiar EXIT

# Si ya hay un archivo, se guarda una copia antes de sobrescribirlo (ver el aviso de arriba:
# lo generado puede ser parcial mientras falten apps).
if [[ -f "$SALIDA" ]]; then
    cp "$SALIDA" "$SALIDA.anterior"
    echo "==> El archivo anterior se guardó como $SALIDA.anterior"
fi

echo "==> Creando la base temporal $BASE_TEMPORAL"
psql -d postgres -qc "CREATE DATABASE \"$BASE_TEMPORAL\""

echo "==> Corriendo las migraciones"
cd "$BACKEND"
DATABASE_URL="" \
DB_NAME="$BASE_TEMPORAL" \
DB_USER="${PGUSER:-postgres}" \
DB_PASSWORD="${PGPASSWORD:-}" \
DB_HOST="${PGHOST:-localhost}" \
DB_PORT="${PGPORT:-5432}" \
    "$PYTHON" manage.py migrate --no-input >/dev/null

echo "==> Sacando el esquema con pg_dump"
# Sin --schema: la base temporal solo tiene lo que crearon las migraciones (public y lab), y
# así el archivo sale con la misma forma que el pgAdminBase.sql anterior. Con --schema=public
# pg_dump agrega un "CREATE SCHEMA public" que falla al cargarlo, porque toda base ya lo trae.
pg_dump --schema-only --no-owner --no-privileges --no-comments \
        -d "$BASE_TEMPORAL" > "$SALIDA.tmp"

# SET transaction_timeout solo existe en PostgreSQL 17 y posteriores: pg_dump lo escribe si
# corre con un cliente 17+, y entonces el archivo falla al cargarlo en PostgreSQL 15 o 16
# (los servidores que usa la empresa). Se deja comentado, igual que en base_total_jupaca.sql.
sed -i 's/^SET transaction_timeout = 0;/-- SET transaction_timeout = 0;   -- solo PostgreSQL 17+; en 15\/16 da error/' "$SALIDA.tmp"

{
    echo "-- Base central de JUPACA PROYECTA: estructura completa (tablas, llaves, CHECK e índices), sin datos."
    echo "-- Incluye el esquema lab (LIMS), que crea la migración lab/0001_initial."
    echo "-- PostgreSQL 15 o superior. Cargar en una base VACÍA; en pgAdmin 4: Query Tool → abrir archivo → F5."
    echo "--"
    echo "-- Generado con backend/sql/generar.sh desde las migraciones de Django. NO EDITAR A MANO:"
    echo "-- los cambios de esquema se hacen en los modelos y con makemigrations."
    echo "-- Generado el $(date '+%Y-%m-%d %H:%M')."
    echo ""
    cat "$SALIDA.tmp"
} > "$SALIDA"
rm -f "$SALIDA.tmp"

echo "==> Listo: $SALIDA"
grep -c '^CREATE TABLE' "$SALIDA" | sed 's/^/    tablas: /'

# Avisar con qué apps se generó, para que se note si el archivo salió parcial.
APPS=$(DATABASE_URL="" DB_NAME="postgres" DB_USER="${PGUSER:-postgres}" DB_PASSWORD="${PGPASSWORD:-}" \
       DB_HOST="${PGHOST:-localhost}" DB_PORT="${PGPORT:-5432}" \
       "$PYTHON" -c "
import django, os
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings.development')
django.setup()
from django.apps import apps
propias = [a.label for a in apps.get_app_configs() if not a.name.startswith('django.')]
print(' '.join(sorted(propias)))
" 2>/dev/null || echo "(no se pudo leer)")

echo ""
echo "    Apps del proyecto incluidas: $APPS"
for FALTA in rrhh finanzas lectura gestion; do
    case " $APPS " in
        *" $FALTA "*) ;;
        *) echo "    AVISO: no existe la app '$FALTA', así que sus tablas NO están en este archivo." ;;
    esac
done
