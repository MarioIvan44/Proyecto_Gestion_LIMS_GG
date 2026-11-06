"""
Motor de lectura de hojas: Python puro, sin Django.

Recibe lo que devolvió el servicio de lectura (texto y confianza por celda) y lo
que el sistema ha aprendido de revisiones anteriores, y produce una PROPUESTA por
celda. La propuesta nunca es el valor final: siempre la confirma o corrige una
persona en la pantalla de revisión.

Módulos:
- texto: normalización y alineación de textos (para comparar y para aprender).
- confusiones: qué caracteres se confunden al leer la letra de la hoja.
- vocabularios: listas cerradas de valores (símbolos SUCS, PLAS/NP...).
- plantillas: qué campos tiene cada tipo de hoja.
- validaciones: reglas entre campos de una fila (N = tramo 2 + tramo 3...).
- propuestas: arma la propuesta de cada celda y de la hoja completa.
- proveedores: interfaz con los servicios de lectura.
"""
