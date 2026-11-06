"""
Correcciones explícitas: lo que la empresa decide corregir de los datos de origen.

MongoDB no se toca. Las correcciones se aplican a una copia del documento en
memoria, justo antes de convertirlo, y cada una queda listada en el informe.

Formato de `correcciones.yaml` (fuera de git; puede tener datos de clientes):

    - coleccion: projects
      _id: "6aea63c0bf10e0795ffc393f"   # siempre entre comillas
      campo: status                # admite rutas con punto: paymentHistory.0.amount
      valor: in progress
      motivo: La empresa confirmó que el proyecto sigue en curso (correo del 10-nov-2026).

    - coleccion: customers
      _id: "6aea63c0bf10e0795ffc393c"
      campo: email
      quitar: true                 # elimina el campo del documento
      motivo: Correo duplicado; el cliente usa el del otro registro.

    - coleccion: contracts
      _id: "6aea63c0bf10e0795ffc3946"
      omitir: true                 # no migrar este documento
      motivo: Contrato cargado por error.
"""

import copy
from collections import defaultdict
from pathlib import Path

import yaml


class CorreccionInvalida(Exception):
    pass


class Correcciones:
    def __init__(self, entradas=()):
        self.por_documento = defaultdict(list)
        for i, entrada in enumerate(entradas, start=1):
            if not isinstance(entrada, dict):
                raise CorreccionInvalida(f"La corrección {i} no es una lista de campos.")
            faltan = [c for c in ("coleccion", "_id", "motivo") if entrada.get(c) in (None, "")]
            if faltan:
                raise CorreccionInvalida(f"A la corrección {i} le falta: {', '.join(faltan)}.")
            if not isinstance(entrada["_id"], str):
                raise CorreccionInvalida(f"En la corrección {i}, escribe el _id entre comillas (\"{entrada['_id']}\"); "
                                         "sin comillas YAML lo puede leer como número.")
            acciones = sum(bool(entrada.get(c)) for c in ("omitir", "quitar")) + ("valor" in entrada)
            if acciones != 1:
                raise CorreccionInvalida(f"La corrección {i} debe tener exactamente una acción: valor, quitar u omitir.")
            if ("valor" in entrada or entrada.get("quitar")) and not entrada.get("campo"):
                raise CorreccionInvalida(f"A la corrección {i} le falta el campo.")
            self.por_documento[(entrada["coleccion"], str(entrada["_id"]))].append({**entrada, "numero": i})
        self.usadas = set()

    @classmethod
    def desde_archivo(cls, ruta):
        if not ruta:
            return cls()
        ruta = Path(ruta)
        if not ruta.exists():
            return cls()
        datos = yaml.safe_load(ruta.read_text(encoding="utf-8")) or []
        if not isinstance(datos, list):
            raise CorreccionInvalida(f"{ruta} debe contener una lista de correcciones.")
        return cls(datos)

    def __len__(self):
        return sum(len(v) for v in self.por_documento.values())

    def aplicar(self, coleccion, doc, informe):
        """Devuelve (documento corregido, omitir)."""
        entradas = self.por_documento.get((coleccion, str(doc["_id"])))
        if not entradas:
            return doc, False
        doc = copy.deepcopy(doc)
        omitir = False
        for entrada in entradas:
            self.usadas.add(entrada["numero"])
            if entrada.get("omitir"):
                omitir = True
                descripcion = "documento omitido"
            elif entrada.get("quitar"):
                _quitar(doc, entrada["campo"])
                descripcion = f"se quitó «{entrada['campo']}»"
            else:
                anterior = _poner(doc, entrada["campo"], entrada["valor"])
                descripcion = f"«{entrada['campo']}»: {anterior!r} → {entrada['valor']!r}"
            informe.correcciones.append({
                "coleccion": coleccion, "mongo_id": str(doc["_id"]), "cambio": descripcion, "motivo": entrada["motivo"],
            })
        return doc, omitir

    def sin_usar(self):
        return [e for lista in self.por_documento.values() for e in lista if e["numero"] not in self.usadas]


def _partes(ruta):
    return [int(p) if p.isdigit() else p for p in ruta.split(".")]


def _contenedor(doc, partes):
    actual = doc
    for parte in partes[:-1]:
        actual = actual[parte]
    return actual


def _poner(doc, ruta, valor):
    partes = _partes(ruta)
    try:
        contenedor = _contenedor(doc, partes)
        anterior = contenedor[partes[-1]] if (isinstance(contenedor, list) or partes[-1] in contenedor) else None
        contenedor[partes[-1]] = valor
    except (KeyError, IndexError, TypeError):
        raise CorreccionInvalida(f"No existe la ruta «{ruta}» en el documento {doc['_id']}.")
    return anterior


def _quitar(doc, ruta):
    partes = _partes(ruta)
    try:
        contenedor = _contenedor(doc, partes)
        if isinstance(contenedor, list):
            contenedor.pop(partes[-1])
        else:
            contenedor.pop(partes[-1], None)
    except (KeyError, IndexError, TypeError):
        raise CorreccionInvalida(f"No existe la ruta «{ruta}» en el documento {doc['_id']}.")
