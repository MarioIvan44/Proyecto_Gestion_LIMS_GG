"""
Le dice a PostgreSQL quién está trabajando, para los triggers del esquema lab.

Los triggers del LIMS (aprobación solo por supervisor, protección de ensayos aprobados,
historial de ubicaciones y auditoría) leen la variable de sesión `lab.usuario_id` con la
función lab.usuario_actual(). Antes la sacaban del JWT de Supabase; ahora la fija el backend
en cada transacción:

    select set_config('lab.usuario_id', '<uuid de nucleo_usuario>', true);

El tercer parámetro (true) hace que el valor dure solo la transacción, así que no se queda
pegado a la conexión cuando esta vuelve al pool.

Cómo usarlo: agregar "lab.middleware.UsuarioLabMiddleware" a MIDDLEWARE, después del
middleware de autenticación de Django. Cada petición queda envuelta en una transacción.

Para procesos que no son peticiones (comandos, tareas, scripts) está el administrador de
contexto `usuario_lab`:

    with usuario_lab(usuario, motivo_correccion="se corrigió la carga mal digitada"):
        resultado.carga_kn = 350
        resultado.save()

Sin esta variable los triggers dejan pasar los cambios (para que funcionen las migraciones y
los scripts) pero la auditoría queda sin autor y nadie puede aprobar resultados.
"""

from contextlib import contextmanager

from django.db import connection, transaction


def _fijar(nombre, valor):
    """set_config(nombre, valor, true): solo para la transacción en curso."""
    with connection.cursor() as cursor:
        cursor.execute("select set_config(%s, %s, true)", [nombre, "" if valor is None else str(valor)])


@contextmanager
def usuario_lab(usuario=None, motivo_correccion=None):
    """
    Abre una transacción diciéndole a la base quién trabaja y, si aplica, por qué corrige.

    `usuario` es una instancia de nucleo.Usuario (o su id). Si va vacío, la auditoría queda
    sin autor, igual que en un script.
    """
    usuario_id = getattr(usuario, "pk", usuario)
    with transaction.atomic():
        _fijar("lab.usuario_id", usuario_id)
        if motivo_correccion:
            _fijar("lab.motivo_correccion", motivo_correccion)
        yield


class UsuarioLabMiddleware:
    """
    Envuelve cada petición en una transacción con lab.usuario_id fijado.

    El motivo de corrección no se pone aquí: lo pide la vista que corrige un resultado ya
    aprobado, con `usuario_lab(request.user, motivo_correccion=...)` o llamando a
    `fijar_motivo_correccion`.
    """

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        usuario = getattr(request, "user", None)
        if usuario is not None and not usuario.is_authenticated:
            usuario = None
        with usuario_lab(usuario):
            return self.get_response(request)

    def process_exception(self, request, exception):
        """
        Si la vista lanza un error, se deshace todo lo que guardó en la petición.

        Django convierte el error en una respuesta 500 antes de que vuelva aquí, así que sin
        esto la transacción de __call__ terminaba normal y guardaba los cambios a medias.
        """
        transaction.set_rollback(True)
        return None


def fijar_motivo_correccion(motivo):
    """
    Deja el motivo con el que la base permitirá corregir un ensayo ya aprobado.

    Se llama dentro de la misma transacción en la que se guarda la corrección (dentro de la
    petición, si se usa el middleware).
    """
    _fijar("lab.motivo_correccion", motivo)
