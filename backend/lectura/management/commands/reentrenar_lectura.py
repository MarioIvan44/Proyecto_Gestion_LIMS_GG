"""
python manage.py reentrenar_lectura

Borra lo aprendido (sinónimos aprendidos y confusiones) y lo vuelve a calcular
desde todas las hojas revisadas del conjunto «entrenamiento». Los sinónimos
cargados por la empresa no se tocan.
"""

from django.core.management.base import BaseCommand

from lectura import aprendizaje


class Command(BaseCommand):
    help = "Recalcula lo aprendido desde las hojas revisadas."

    def handle(self, *args, **opciones):
        r = aprendizaje.reconstruir()
        self.stdout.write(
            f"Hojas usadas: {r['hojas']} · sinónimos: {r['sinonimos']} · confusiones distintas: {r['confusiones']}"
        )
