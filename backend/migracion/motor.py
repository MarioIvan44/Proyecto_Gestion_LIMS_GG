"""
Motor de la migración: lee MongoDB (solo lectura), convierte y guarda en PostgreSQL.

Cómo garantiza que se puede repetir sin duplicar:
- Cada fila guarda el `_id` de su documento en `mongo_id` (único). Si la fila ya
  existe se actualiza; si no, se inserta.
- Los documentos se procesan en orden de creación, así que cuando dos chocan en
  un campo único siempre se conserva el más antiguo, en todas las corridas.

Cada documento se guarda dentro de su propio punto de recuperación (savepoint):
si falla, se deshace solo ese documento y queda en el informe con el motivo.
"""

from collections import defaultdict
from datetime import datetime, timezone
from decimal import Decimal

from bson import Decimal128, ObjectId
from django.contrib.auth.hashers import make_password
from django.db import IntegrityError, transaction

from nucleo.ids import uuid7_desde_objectid
from nucleo.models import Usuario

from .conversiones import BCRYPT, Contexto, Rechazo, a_json, fecha_hora, objectid_de
from .mapeos import (
    ADMINISTRADORES, CAMPOS_META, CAMPOS_USUARIO_EMPLEADO, COLECCIONES, EMPLEADOS, MARCAS_DEMO,
    MENSAJES_RESTRICCIONES, ORDEN, PLANILLAS, USUARIOS,
)

NOMBRES = {
    "departments": "el departamento", "employees": "el empleado", "administrators": "el administrador",
    "customers": "el cliente", "services": "el servicio", "projects": "el proyecto",
    "weeklyreports": "el reporte semanal", "contracts": "el contrato", "overtimerecords": "el registro de horas extra",
    "payrolls": "la planilla", "payrollentries": "la línea de planilla", "payslips": "la boleta",
    "proformainvoices": "la proforma", "accountsreceivables": "la cuenta por cobrar", USUARIOS: "la cuenta",
}


class SoloLectura:
    """Envuelve la base MongoDB y expone solo operaciones de lectura."""

    def __init__(self, db):
        self._db = db

    @property
    def nombre(self):
        return self._db.name

    def colecciones(self):
        return set(self._db.list_collection_names())

    def documentos(self, coleccion):
        return list(self._db[coleccion].find({}))

    def contar(self, coleccion):
        return self._db[coleccion].count_documents({})


def _decimal_crudo(valor):
    """Valor original de MongoDB como Decimal, sin redondear (para comparar sumas)."""
    if isinstance(valor, bool) or valor is None:
        return None
    if isinstance(valor, Decimal128):
        return valor.to_decimal()
    if isinstance(valor, (int, Decimal)):
        return Decimal(valor)
    if isinstance(valor, float):
        return Decimal(repr(valor))
    if isinstance(valor, str):
        try:
            return Decimal(valor)
        except Exception:
            return None
    return None


def _momento_creacion(doc):
    creado = doc.get("createdAt")
    if isinstance(creado, datetime):
        return creado if creado.tzinfo else creado.replace(tzinfo=ObjectId(doc["_id"]).generation_time.tzinfo)
    oid = doc.get("_id")
    return oid.generation_time if isinstance(oid, ObjectId) else datetime.min.replace(tzinfo=timezone.utc)


def mensaje_integridad(error):
    causa = error.__cause__
    diag = getattr(causa, "diag", None)
    nombre = getattr(diag, "constraint_name", None)
    if nombre in MENSAJES_RESTRICCIONES:
        return MENSAJES_RESTRICCIONES[nombre]
    columna = getattr(diag, "column_name", None)
    if columna:
        return f"la base rechazó el valor de la columna «{columna}»"
    return f"la base rechazó la fila ({nombre or type(causa).__name__})"


class Motor:
    def __init__(self, origen: SoloLectura, informe, incluir_demo=False, log=print, correcciones=None):
        self.origen = origen
        self.correcciones = correcciones
        self.informe = informe
        self.incluir_demo = incluir_demo
        self.log = log
        self.ids = defaultdict(dict)  # colección -> {_id: pk en PostgreSQL}
        self.motivos = defaultdict(dict)  # colección -> {_id: por qué no se migró}
        self.escritos = defaultdict(set)  # modelo -> mongo_id guardados en esta corrida
        self.todos_ids = defaultdict(set)  # modelo -> todos los _id vistos en MongoDB
        self.sumas = defaultdict(lambda: [0, Decimal(0)])  # (modelo, columna) -> [filas, suma original]
        self.hijos_vistos = defaultdict(dict)  # modelo hijo -> {mongo_id: _id del padre}

    # ------------------------------------------------------------------ general

    def ejecutar(self):
        existentes = self.origen.colecciones()
        for coleccion in ORDEN:
            self.migrar_coleccion(coleccion, coleccion.nombre in existentes)
        for nombre in sorted(existentes - set(COLECCIONES)):
            if not nombre.startswith("system."):
                self.informe.no_reconocidas[nombre] = self.origen.contar(nombre)

    def migrar_coleccion(self, col, existe):
        modelo = col.modelo
        stats = self.informe.coleccion(col.nombre, modelo._meta.db_table)
        if not existe:
            self.log(f"  {col.nombre}: no existe en MongoDB")
            return
        documentos = self.origen.documentos(col.nombre)
        documentos.sort(key=lambda d: (_momento_creacion(d), str(d.get("_id"))))
        stats.total_mongo = len(documentos)
        for doc in documentos:
            oid = str(doc["_id"])
            self.todos_ids[modelo].add(oid)
            if self.correcciones is not None:
                doc, omitir = self.correcciones.aplicar(col.nombre, doc, self.informe)
                if omitir:
                    stats.omitidos += 1
                    self.motivos[col.nombre][oid] = "omitido por una corrección"
                    continue
            if doc.get("isSeedData") is True and not self.incluir_demo:
                stats.excluidos_demo += 1
                self.motivos[col.nombre][oid] = "es de demostración (excluido)"
                continue
            ctx = Contexto(col.nombre, oid)
            ctx.sumas, ctx.extras, ctx.ids, ctx.escritos = [], [], [], []
            try:
                with transaction.atomic():
                    pk, insertado = self.procesar(col, doc, ctx)
            except Rechazo as r:
                self.rechazar(col, oid, r.campo, r.motivo)
                continue
            except IntegrityError as e:
                self.rechazar(col, oid, None, mensaje_integridad(e))
                continue
            self.confirmar(col, modelo, oid, pk, ctx)
            if insertado:
                stats.insertados += 1
            else:
                stats.actualizados += 1
        self.log(f"  {col.nombre}: {stats.total_mongo} documentos, {stats.excluidos_demo} demo excluidos, "
                 f"{stats.insertados} insertados, {stats.actualizados} actualizados, {stats.rechazados} rechazados")

    def rechazar(self, col, oid, campo, motivo):
        existente = col.modelo.objects.filter(mongo_id=oid).values_list("pk", flat=True).first()
        self.informe.rechazo(col.nombre, oid, campo, motivo, conservada=existente is not None)
        self.informe.colecciones[col.nombre].rechazados += 1
        self.motivos[col.nombre][oid] = motivo
        if existente is not None:
            # La fila de una corrida anterior sigue en la base: quien apunte a
            # este documento puede seguir enlazándose a ella.
            self.ids[col.nombre][oid] = existente
            if col is ADMINISTRADORES:
                self.ids[USUARIOS][oid] = existente
        if col is EMPLEADOS:
            usuario = Usuario.objects.filter(mongo_id=oid).values_list("pk", flat=True).first()
            if usuario is not None:
                self.ids[USUARIOS][oid] = usuario

    def confirmar(self, col, modelo, oid, pk, ctx):
        self.informe.confirmar(ctx)
        self.ids[col.nombre][oid] = pk
        self.escritos[modelo].add(oid)
        for coleccion, clave, valor in ctx.ids:
            self.ids[coleccion][clave] = valor
        for modelo_escrito, clave in ctx.escritos:
            self.escritos[modelo_escrito].add(clave)
        for modelo_suma, columna, crudo in ctx.sumas:
            acumulado = self.sumas[(modelo_suma, columna)]
            acumulado[0] += 1
            acumulado[1] += crudo
        for nombre in ctx.extras:
            self.informe.campos_extra[col.nombre][nombre] += 1

    # --------------------------------------------------------------- documento

    def procesar(self, col, doc, ctx):
        oid = str(doc["_id"])
        valores = self.convertir_campos(col.campos, col.modelo, doc, ctx)
        valores.update(self.resolver_refs(col.refs, doc, ctx))
        valores["datos_extra"] = self.datos_extra(col, doc, ctx)
        valores.update(self.fechas(col, doc, ctx))

        if col is PLANILLAS:
            self.ajustar_planilla(doc, valores, ctx)
        if col is ADMINISTRADORES:
            valores["password"] = self.password(doc, ctx)
            valores["tipo"] = Usuario.Tipo.ADMINISTRADOR
            ctx.ids.append((USUARIOS, oid, None))  # se completa con el pk abajo

        self.verificar_unicos(col, valores, oid)
        if col is EMPLEADOS:
            valores["usuario_id"] = self.usuario_de_empleado(doc, valores, ctx)

        pk, insertado = self.guardar(col.modelo, oid, valores)
        if col is ADMINISTRADORES:
            ctx.ids[-1] = (USUARIOS, oid, pk)
        for hijos in col.hijos:
            self.guardar_hijos(col, hijos, doc, pk, oid, ctx)
        return pk, insertado

    def convertir_campos(self, campos, modelo, doc, ctx):
        valores = {}
        for campo in campos:
            crudo = doc.get(campo.origen)
            valor = campo.convertir(crudo, ctx, campo.origen)
            if valor is None and crudo is None and campo.por_defecto is not None:
                valor = campo.por_defecto
                ctx.contar("valor por defecto del esquema (faltaba)", campo.origen)
            if campo.obligatorio and (valor is None or valor == ""):
                raise Rechazo(campo.origen, "falta o está vacío (es obligatorio)")
            valores[campo.destino] = valor
            if campo.suma and valor is not None:
                original = _decimal_crudo(crudo) if crudo is not None else Decimal(str(valor))
                if original is not None:
                    ctx.sumas.append((modelo, campo.destino, original))
        return valores

    def resolver_refs(self, refs, doc, ctx):
        valores = {}
        for ref in refs:
            columna = f"{ref.destino}_id"
            crudo = doc.get(ref.origen)
            if crudo is None or crudo == "":
                if ref.obligatoria:
                    raise Rechazo(ref.origen, "falta la referencia (es obligatoria)")
                valores[columna] = None
                continue
            oid, era_texto = objectid_de(crudo)
            if oid is None:
                mensaje = f"no es un ObjectId válido ({crudo!r})"
                if ref.obligatoria:
                    raise Rechazo(ref.origen, mensaje)
                ctx.advertir(ref.origen, mensaje + "; se dejó vacía")
                valores[columna] = None
                continue
            if era_texto:
                ctx.contar("referencia guardada como texto", ref.origen)
            pk = self.ids[ref.coleccion].get(str(oid))
            if pk is None:
                motivo = self.motivo_referencia(ref.coleccion, str(oid))
                if ref.obligatoria:
                    raise Rechazo(ref.origen, motivo)
                ctx.advertir(ref.origen, motivo + "; se dejó vacía")
            valores[columna] = pk
        return valores

    def motivo_referencia(self, coleccion, oid):
        nombre = NOMBRES.get(coleccion, coleccion)
        fuentes = ["employees", "administrators"] if coleccion == USUARIOS else [coleccion]
        for fuente in fuentes:
            if oid in self.motivos[fuente]:
                return f"{nombre} {oid} no se migró ({self.motivos[fuente][oid]})"
        return f"{nombre} {oid} no existe en MongoDB"

    def datos_extra(self, col, doc, ctx, conocidos=None):
        if conocidos is None:
            meta = CAMPOS_META if col.con_fechas else CAMPOS_META - {"createdAt", "updatedAt"}
            conocidos = (meta | {c.origen for c in col.campos} | {r.origen for r in col.refs}
                         | {h.arreglo for h in col.hijos} | set(col.campos_especiales))
        extra = {}
        for clave, valor in doc.items():
            if clave in MARCAS_DEMO:
                if self.incluir_demo:
                    extra[clave] = a_json(valor)
                continue
            if clave in conocidos:
                continue
            extra[clave] = a_json(valor)
            ctx.extras.append(clave)
        if "password" in doc:
            ctx.advertir("password", "el documento tenía un campo «password»; por seguridad no se migra")
        return extra

    def fechas(self, col, doc, ctx):
        nacimiento = doc["_id"].generation_time if isinstance(doc["_id"], ObjectId) else None
        if not col.con_fechas:
            # El esquema no guarda fechas. Si el documento las trae de todos modos (por
            # ejemplo, los de demostración), se usan y además quedan en datos_extra.
            creado, actualizado = doc.get("createdAt"), doc.get("updatedAt")
            if isinstance(creado, datetime):
                actualizado = actualizado if isinstance(actualizado, datetime) else creado
                return {"creado_en": creado, "actualizado_en": actualizado}
            ctx.contar("fecha de creación tomada del ObjectId (el esquema no guarda fechas)", "_id")
            return {"creado_en": nacimiento, "actualizado_en": nacimiento}
        convertir = fecha_hora()
        try:
            creado = convertir(doc.get("createdAt"), ctx, "createdAt")
            actualizado = convertir(doc.get("updatedAt"), ctx, "updatedAt")
        except Rechazo as r:
            ctx.advertir(r.campo, f"{r.motivo}; se tomó la fecha del ObjectId")
            creado = actualizado = None
        if creado is None:
            ctx.advertir("createdAt", "no tenía fecha de creación; se tomó la del ObjectId")
            creado = nacimiento
        return {"creado_en": creado, "actualizado_en": actualizado or creado}

    def verificar_unicos(self, col, valores, oid):
        for unico in col.unicos:
            filtro = unico.filtro(valores)
            if not filtro:
                continue
            otros = list(col.modelo.objects.filter(**filtro).exclude(mongo_id=oid).values_list("mongo_id", "pk")[:1])
            if not otros:
                continue
            otro_mongo, otro_pk = otros[0]
            campo = next(iter(filtro)).split("__")[0]
            if col is ADMINISTRADORES:
                tipo = Usuario.objects.filter(pk=otro_pk).values_list("tipo", flat=True).first()
                if tipo == Usuario.Tipo.EMPLEADO:
                    raise Rechazo("email", f"el correo ya lo usa el empleado {otro_mongo}; en el sistema actual este "
                                           "administrador no podía iniciar sesión (el inicio de sesión busca primero en empleados)")
            quien = f"documento {otro_mongo}" if otro_mongo else "una fila creada directamente en PostgreSQL"
            raise Rechazo(campo, f"{unico.mensaje} ({quien})")

    def guardar(self, modelo, oid, valores, variante=0):
        actualizadas = modelo.objects.filter(mongo_id=oid).update(**valores)
        if actualizadas:
            return modelo.objects.filter(mongo_id=oid).values_list("pk", flat=True).get(), False
        # Fila nueva: su UUID se deriva del ObjectId (mismo orden que en MongoDB).
        objeto = modelo(id=self.id_derivado(oid, variante), mongo_id=oid, **valores)
        modelo.objects.bulk_create([objeto])
        return objeto.pk, True

    @staticmethod
    def id_derivado(oid, variante=0):
        if "." in oid:  # subdocumento sin _id: <_id del padre>.<posición>
            padre, posicion = oid.rsplit(".", 1)
            return uuid7_desde_objectid(padre, 2 + int(posicion))
        return uuid7_desde_objectid(oid, variante)

    # ------------------------------------------------------------ casos propios

    def password(self, doc, ctx):
        valor = doc.get("passwordHash")
        if isinstance(valor, str) and BCRYPT.match(valor):
            return f"bcrypt${valor}"
        if valor in (None, ""):
            ctx.contar("cuenta sin contraseña (no puede iniciar sesión)", "passwordHash")
        else:
            ctx.advertir("passwordHash", "no es un hash bcrypt válido: la cuenta quedó sin contraseña utilizable (hay que generarle una nueva)")
        return make_password(None)

    def usuario_de_empleado(self, doc, empleado, ctx):
        oid = str(doc["_id"])
        datos = self.convertir_campos(CAMPOS_USUARIO_EMPLEADO, Usuario, doc, ctx)
        email = empleado.get("email")
        if not email:
            if doc.get("passwordHash") or doc.get("hasAccess"):
                ctx.advertir("email", "no tiene correo, así que no puede iniciar sesión: sus datos de acceso no se migraron")
            return None
        otros = list(Usuario.objects.filter(email__iexact=email).exclude(mongo_id=oid).values_list("mongo_id", "tipo")[:1])
        if otros:
            otro_mongo, tipo = otros[0]
            raise Rechazo("email", f"el correo ya lo usa la cuenta de {tipo} {otro_mongo or '(creada directamente en PostgreSQL)'}")
        usuario = {
            **datos,
            "email": email,
            "nombres": empleado.get("nombres") or "",
            "apellidos": empleado.get("apellidos") or "",
            "tipo": Usuario.Tipo.EMPLEADO,
            "password": self.password(doc, ctx),
            "is_active": True,
            "datos_extra": {},
            "creado_en": empleado["creado_en"],
            "actualizado_en": empleado["actualizado_en"],
        }
        # variante 1: la cuenta sale del mismo documento que el empleado, pero con otro UUID.
        pk, _ = self.guardar(Usuario, oid, usuario, variante=1)
        ctx.ids.append((USUARIOS, oid, pk))
        ctx.escritos.append((Usuario, oid))
        return pk

    def ajustar_planilla(self, doc, valores, ctx):
        original = doc.get("seedOriginalTotal")
        if original is None or self.incluir_demo:
            return
        from .conversiones import decimal

        valores["total"] = decimal()(original, ctx, "seedOriginalTotal")
        ctx.advertir("totalAmount", f"el total ({doc.get('totalAmount')}) incluía filas de demostración; "
                                    f"se guardó el total original del equipo ({original})")
        ctx.sumas = [s for s in ctx.sumas if s[1] != "total"]
        crudo = _decimal_crudo(original)
        if crudo is not None:
            ctx.sumas.append((PLANILLAS.modelo, "total", crudo))

    # ----------------------------------------------------------------- arreglos

    def guardar_hijos(self, col, hijos, doc, padre_pk, padre_oid, ctx):
        modelo = hijos.modelo
        nombre = f"{col.nombre}.{hijos.arreglo}"
        stats = self.informe.hijo(col.nombre, hijos.arreglo, modelo._meta.db_table)
        arreglo = doc.get(hijos.arreglo)
        if arreglo is None:
            arreglo = []
        if not isinstance(arreglo, list):
            ctx.advertir(hijos.arreglo, f"se esperaba un arreglo y vino {type(arreglo).__name__}; no se tocaron sus elementos")
            return
        conocidos = {"_id"} | {c.origen for c in hijos.campos} | {r.origen for r in hijos.refs}
        actuales, claves = [], set()
        for posicion, sub in enumerate(arreglo):
            stats.elementos += 1
            sub_oid = str(sub["_id"]) if isinstance(sub, dict) and "_id" in sub else f"{padre_oid}.{posicion}"
            hctx = Contexto(nombre, sub_oid)
            hctx.sumas, hctx.extras, hctx.ids = [], [], []
            try:
                if not isinstance(sub, dict):
                    raise Rechazo(hijos.arreglo, f"el elemento {posicion} no es un subdocumento ({sub!r})")
                if "_id" not in sub:
                    hctx.contar("subdocumento sin _id (se usó <_id del padre>.<posición>)", "_id")
                otro_padre = self.hijos_vistos[modelo].get(sub_oid)
                if otro_padre and otro_padre != padre_oid:
                    raise Rechazo("_id", f"el mismo _id de elemento aparece también en el documento {otro_padre}")
                valores = self.convertir_campos(hijos.campos, modelo, sub, hctx)
                valores.update(self.resolver_refs(hijos.refs, sub, hctx))
                valores["datos_extra"] = self.datos_extra(col, sub, hctx, conocidos=conocidos)
                valores["posicion"] = posicion
                valores[f"{hijos.padre}_id"] = padre_pk
                if hijos.unico_en_padre:
                    clave = tuple(valores.get(c) for c in hijos.unico_en_padre)
                    if clave in claves:
                        raise Rechazo(hijos.arreglo, "elemento repetido dentro del mismo documento (se conserva el primero)")
                    claves.add(clave)
                padre_actual = modelo.objects.filter(mongo_id=sub_oid).values_list(f"{hijos.padre}_id", flat=True).first()
                if padre_actual is not None and padre_actual != padre_pk:
                    raise Rechazo("_id", "ese _id de elemento ya está guardado bajo otro documento")
                with transaction.atomic():
                    self.guardar(modelo, sub_oid, valores)
            except Rechazo as r:
                self.rechazar_hijo(stats, nombre, sub_oid, r.campo, r.motivo, padre_oid, ctx, hijos.arreglo)
                continue
            except IntegrityError as e:
                self.rechazar_hijo(stats, nombre, sub_oid, None, mensaje_integridad(e), padre_oid, ctx, hijos.arreglo)
                continue
            self.hijos_vistos[modelo][sub_oid] = padre_oid
            actuales.append(sub_oid)
            stats.migrados += 1
            self.escritos[modelo].add(sub_oid)
            self.informe.confirmar(hctx)
            for modelo_suma, columna, crudo in hctx.sumas:
                acumulado = self.sumas[(modelo_suma, columna)]
                acumulado[0] += 1
                acumulado[1] += crudo
            for extra in hctx.extras:
                self.informe.campos_extra[nombre][extra] += 1

        sobrantes = modelo.objects.filter(**{f"{hijos.padre}_id": padre_pk}).exclude(mongo_id__isnull=True).exclude(mongo_id__in=actuales)
        lista = list(sobrantes.values_list("mongo_id", flat=True))
        if lista:
            sobrantes.delete()
            stats.eliminados += len(lista)
            ctx.advertir(hijos.arreglo, f"se eliminaron {len(lista)} elementos que ya no están en el arreglo: {', '.join(lista)}")

    def rechazar_hijo(self, stats, nombre, sub_oid, campo, motivo, padre_oid, ctx, arreglo):
        stats.rechazados += 1
        self.informe.rechazo(nombre, sub_oid, campo, f"{motivo} (documento {padre_oid})")
        ctx.advertir(arreglo, f"el elemento {sub_oid} no se migró: {motivo}")
