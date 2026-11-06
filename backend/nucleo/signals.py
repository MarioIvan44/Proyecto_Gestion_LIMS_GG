"""Reglas que acompañan a los modelos de núcleo."""

from django.db.models.signals import post_delete
from django.dispatch import receiver

from .models import Empleado


@receiver(post_delete, sender=Empleado)
def borrar_cuenta_del_empleado(sender, instance, **kwargs):
    """Al borrar un empleado se borra su cuenta de acceso (así su correo puede volver a usarse)."""
    if instance.usuario_id:
        from .models import Usuario

        Usuario.objects.filter(pk=instance.usuario_id, tipo=Usuario.Tipo.EMPLEADO).delete()
