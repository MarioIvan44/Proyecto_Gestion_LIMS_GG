"""
Listas cerradas de valores para los campos de opción.

Los símbolos son los de ASTM D2487 (SUCS). Si la hoja trae un valor fuera de la
lista (por ejemplo «MH/CL»), el sistema no lo cambia por su cuenta: queda para
que el revisor decida y anote el motivo.
"""

SIMBOLO_USCS = "simbolo_uscs"
PLASTICIDAD = "plasticidad"
ENSAYO_ATTERBERG = "ensayo_atterberg"

# Vocabulario abierto: sinónimos de palabras sueltas en campos de texto libre
# (descripciones). No tiene lista cerrada; solo se usa para aprender reemplazos.
PALABRAS = "palabras"

VOCABULARIOS = {
    SIMBOLO_USCS: (
        "GW", "GP", "GM", "GC", "GW-GM", "GW-GC", "GP-GM", "GP-GC", "GC-GM",
        "SW", "SP", "SM", "SC", "SW-SM", "SW-SC", "SP-SM", "SP-SC", "SC-SM",
        "CL", "ML", "CL-ML", "OL", "CH", "MH", "OH", "PT",
    ),
    PLASTICIDAD: ("PLAS", "NP"),
    # Determinación de límite líquido o de límite plástico en la hoja M04-REG01.
    ENSAYO_ATTERBERG: ("LL", "LP"),
}
