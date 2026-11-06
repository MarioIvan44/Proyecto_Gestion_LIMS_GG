"""
Configuración común del proyecto Django, dueño del esquema de la base central de JUPACA.

- development.py: DEBUG activo, para trabajar en local (es la que usa manage.py).
- production.py: seguridad HTTPS y DEBUG apagado.

Los valores sensibles (clave secreta, cadenas de conexión) se leen de
`backend/.env`, que está fuera del repositorio (ver `.env.example`), o de
variables de entorno, que tienen prioridad.
"""

import os
from pathlib import Path

import dj_database_url
from decouple import Csv, config

# Carpeta backend/
BASE_DIR = Path(__file__).resolve().parent.parent.parent

SECRET_KEY = config("SECRET_KEY")

DEBUG = False

ALLOWED_HOSTS = config("ALLOWED_HOSTS", cast=Csv(), default="localhost,127.0.0.1")

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "django.contrib.postgres",
    # Apps del proyecto
    "nucleo",
    "rrhh",
    "finanzas",
    "migracion",
    "lectura",
    "lab",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    # Le dice a PostgreSQL quién trabaja (variable lab.usuario_id) para los triggers del
    # esquema lab: aprobación solo por supervisor, protección de lo aprobado y auditoría.
    # Va después del de autenticación porque necesita request.user.
    "lab.middleware.UsuarioLabMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "config.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

WSGI_APPLICATION = "config.wsgi.application"
ASGI_APPLICATION = "config.asgi.application"


# ---------------------------------------------------------------------------
# Base de datos: la PostgreSQL central de la empresa (la misma del sistema
# administrativo migrado desde MongoDB).
# ---------------------------------------------------------------------------
def _base_de_datos():
    # Forma principal: una sola cadena postgres://usuario:clave@servidor:puerto/base.
    # La usan también los scripts de prueba de la migración.
    url = config("DATABASE_URL", default="")
    if url:
        return dj_database_url.parse(url, conn_max_age=60)
    # Alternativa: los datos por separado.
    return {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": config("DB_NAME"),
        "USER": config("DB_USER"),
        "PASSWORD": config("DB_PASSWORD"),
        "HOST": config("DB_HOST", default="localhost"),
        "PORT": config("DB_PORT", default="5432"),
        "CONN_MAX_AGE": 60,
    }


DATABASES = {"default": _base_de_datos()}

# Base MongoDB de origen para la migración (solo lectura). Ver migracion/README.md.
MONGO_URI = config("MONGO_URI", default="")
MONGO_DB = config("MONGO_DB", default="")

# ---------------------------------------------------------------------------
# Usuarios y contraseñas
# ---------------------------------------------------------------------------
AUTH_USER_MODEL = "nucleo.Usuario"

# bcrypt va primero: es el mismo algoritmo que usa el backend Node, así que una
# contraseña creada en cualquiera de los dos sistemas funciona en el otro.
PASSWORD_HASHERS = [
    "nucleo.hashers.BcryptCompatibleNodeHasher",
    "django.contrib.auth.hashers.PBKDF2PasswordHasher",
    "django.contrib.auth.hashers.Argon2PasswordHasher",
    "django.contrib.auth.hashers.ScryptPasswordHasher",
]

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator", "OPTIONS": {"min_length": 6}},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]

# Interfaz en español.
LANGUAGE_CODE = "es"
TIME_ZONE = "America/El_Salvador"
USE_I18N = True
USE_TZ = True

STATIC_URL = "static/"
STATIC_ROOT = BASE_DIR / "staticfiles"

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# ---------------------------------------------------------------------------
# Archivos del LIMS (app `lab`): Cloudinary
# ---------------------------------------------------------------------------
# Decisión del equipo (nov-2026): los archivos del laboratorio (certificados de calibración,
# hojas de remisión firmadas, CSV de la prensa, informes en PDF y adjuntos) van a Cloudinary.
# Es un almacenamiento aparte del por defecto, porque el por defecto lo ocupa la app `lectura`,
# cuyas fotos son datos de clientes y se guardan fuera del repositorio sin publicarse.
# Las credenciales se leen de CLOUDINARY_URL (backend/.env), con el formato que da Cloudinary:
#   cloudinary://<api_key>:<api_secret>@<cloud_name>
CLOUDINARY_URL = config("CLOUDINARY_URL", default="")

# La biblioteca de Cloudinary lee la cuenta de la variable de entorno CLOUDINARY_URL, así que
# se copia ahí lo que venga de backend/.env (las variables de entorno reales tienen prioridad).
if CLOUDINARY_URL:
    os.environ.setdefault("CLOUDINARY_URL", CLOUDINARY_URL)
    # SUPUESTO: carpeta raíz dentro de Cloudinary, para no mezclar con otros sistemas de la
    # empresa. Las subcarpetas las pone cada campo (lab/calibraciones/, lab/informes/...).
    CLOUDINARY_STORAGE = {"PREFIX": config("CLOUDINARY_PREFIX", default="")}
    ALMACENAMIENTO_LAB = {"BACKEND": "cloudinary_storage.storage.MediaCloudinaryStorage"}
else:
    # Todavía sin credenciales de Cloudinary: los archivos del laboratorio van al disco, en
    # backend/media/lab/, para poder trabajar y correr pruebas. En cuanto la empresa dé la
    # cuenta, se pone CLOUDINARY_URL en backend/.env y empiezan a subir a Cloudinary sin
    # tocar el código. PENDIENTE: pedir la cuenta (ver PENDIENTES.md).
    ALMACENAMIENTO_LAB = {"BACKEND": "django.core.files.storage.FileSystemStorage"}

STORAGES = {
    # Por defecto: disco, para la app `lectura` (ver MEDIA_ROOT más abajo).
    "default": {"BACKEND": "django.core.files.storage.FileSystemStorage"},
    "staticfiles": {"BACKEND": "django.contrib.staticfiles.storage.StaticFilesStorage"},
    # Archivos del laboratorio. Los campos de lab/models.py lo piden por este nombre
    # (ver lab/storages.py).
    "lab_archivos": ALMACENAMIENTO_LAB,
}

# ---------------------------------------------------------------------------
# Lectura de hojas (app `lectura`)
# ---------------------------------------------------------------------------
# Las fotos de las hojas son datos de clientes: se guardan fuera del repositorio
# y no se publican con MEDIA_URL; la API las entrega solo con sesión iniciada.
MEDIA_ROOT = Path(config("LECTURA_MEDIA_ROOT", default="") or BASE_DIR / "media")
# Servicio que lee las fotos: «manual» (no lee; se captura con la foto al lado) o
# «simulado» (lecturas guardadas en JSON, para pruebas). Ver lectura/motor/proveedores.py.
LECTURA_PROVEEDOR = config("LECTURA_PROVEEDOR", default="manual")
LECTURA_SIMULADO_DIR = config("LECTURA_SIMULADO_DIR", default="")
# SUPUESTO: por debajo de esta confianza la celda se marca para revisión. Calibrar
# con las hojas de referencia (comando medir_exactitud_lectura).
LECTURA_UMBRAL_CONFIANZA = config("LECTURA_UMBRAL_CONFIANZA", cast=float, default=0.90)
# SUPUESTO: tamaño máximo de una foto. Las de teléfono suelen pesar de 2 a 6 MB.
LECTURA_TAMANO_MAXIMO_MB = config("LECTURA_TAMANO_MAXIMO_MB", cast=int, default=20)
FILE_UPLOAD_MAX_MEMORY_SIZE = 5 * 1024 * 1024
