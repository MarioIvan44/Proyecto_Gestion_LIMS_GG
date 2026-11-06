// Agrega a la copia LOCAL de prueba:
//  1. Documentos válidos «del equipo» en colecciones que seedShowcase deja vacías
//     (horas extra, reportes semanales) y una proforma con su cuenta por cobrar.
//  2. Casos «sucios» insertados directo en la colección (sin pasar por las
//     validaciones de Mongoose), como los que pueden existir en datos reales
//     antiguos. Cada caso tiene un resultado esperado en la migración.
//
// Guarda la lista de casos con sus _id y el resultado esperado en el archivo
// indicado por CASOS_PRUEBA, para comprobar después el informe de migración.
//
// Uso: FORK_BACKEND=... DB_URI=mongodb://127.0.0.1:27018/jupaca_copia CASOS_PRUEBA=<archivo> node insertar_casos.mjs
import fs from "node:fs";

import { cargarModelos, dia, uriLocal } from "./comun.mjs";

async function main() {
    const uri = uriLocal();
    const m = await cargarModelos();
    const mongoose = m.customers.base;
    const { ObjectId } = mongoose.Types;
    await mongoose.connect(uri);
    const db = mongoose.connection.db;

    if (await db.collection("customers").countDocuments({ RUC: "CASO-C01" }) > 0) {
        console.log("Los casos de prueba ya están insertados.");
        await mongoose.disconnect();
        return;
    }

    const equipo = { isSeedData: { $ne: true } };
    const ana = await m.employees.findOne({ ...equipo, email: "ana.prueba@example.com" }).lean();
    const bruno = await m.employees.findOne({ ...equipo, email: "bruno.prueba@example.com" }).lean();
    const proyecto = await m.projects.findOne({ ...equipo, projectCode: "EEN-01" }).lean();
    const cliente = await m.customers.findOne({ ...equipo, RUC: "0614-010180-101-1" }).lean();
    const servicio = await m.services.findOne({ name: "Granulometría" }).lean();
    const ahora = new Date();
    // Cada caso con la hora real en que se inserta (como en datos reales).
    const sello = { __v: 0, get createdAt() { return new Date(); }, get updatedAt() { return new Date(); } };
    const casos = [];
    const caso = (codigo, coleccion, _id, esperado, detalle) => casos.push({ codigo, coleccion, _id: String(_id), esperado, detalle });
    const insertar = async (coleccion, doc) => (await db.collection(coleccion).insertOne(doc)).insertedId;

    // ---------------- Datos válidos del equipo ----------------
    const he = await m.overtimeRecords.create({
        projectId: proyecto._id, employeeId: ana._id, periodStart: dia("2026-10-05"), periodEnd: dia("2026-10-11"),
        authorizedBy: "Carla Prueba Ingeniería", regularHours: 40, overtimeHours: 6, costPerHour: 6.5,
        totalOvertimePay: 39, overtimeType: "weekly",
    });
    caso("V01", "overtimerecords", he._id, "importado", "registro de horas extra válido");
    const rs = await m.weeklyReports.create({
        projectId: proyecto._id, reportedBy: ana._id, weekEnding: dia("2026-10-11"),
        notes: "Se completaron 3 sondeos.", status: "submitted", submittedAt: new Date("2026-10-12T14:00:00Z"),
    });
    caso("V02", "weeklyreports", rs._id, "importado", "reporte semanal válido");
    const proforma = await m.proformaInvoices.create({
        customerId: cliente._id, projectId: proyecto._id, issueDate: dia("2026-10-01"),
        items: [{ serviceId: servicio._id, quantity: 3, unitCost: 35.5, subtotal: 106.5 }],
        overtimeCharges: 0, additionalCharges: 0, projectBaseCost: 0, totalAmount: 120.345, status: "approved",
        approvedAt: new Date("2026-10-02T16:00:00Z"),
    });
    caso("V03", "proformainvoices", proforma._id, "importado", "proforma válida del equipo");
    const cuenta = await m.accountsReceivable.create({
        proformaInvoiceId: proforma._id, invoiceNumber: "F-EQUIPO-0001", issueDate: "2026-10-03", dueDate: "2026-11-02",
        items: [{ serviceId: servicio._id, quantity: 3, unitCost: 35.5, subtotal: 106.5 }],
        subtotal: 106.5, taxAmount: 13.845, totalAmount: 120.345, paidAmount: 60, balanceDue: 60.345, status: "Pending",
        paymentHistory: [{ paymentDate: dia("2026-10-10"), amount: 60, method: "Transferencia", notes: "Anticipo" }],
    });
    caso("V04", "accountsreceivables", cuenta._id, "importado", "cuenta por cobrar válida con IVA de 3 decimales");

    // ---------------- Casos sucios ----------------
    let id;
    id = await insertar("customers", { RUC: "CASO-C01", companyName: "Cliente Correo Vacío", contactName: "Caso Uno", email: "", ...sello });
    caso("C01", "customers", id, "importado", "correo vacío pasa a NULL");
    id = await insertar("customers", { RUC: "CASO-C02", companyName: "Cliente Duplicado", contactName: "Caso Dos", email: "COMPRAS@constructora.example.com", ...sello });
    caso("C02", "customers", id, "rechazado", "correo repetido con otras mayúsculas");
    id = await insertar("projects", { customerId: new ObjectId(), projectName: "Proyecto Cliente Borrado", status: "in progress", ...sello });
    caso("C03", "projects", id, "advertencia", "cliente inexistente: se importa sin cliente");
    id = await insertar("projects", { customerId: cliente._id, projectName: "Proyecto Estado Raro", status: "on hold", ...sello });
    caso("C04", "projects", id, "rechazado", "estado fuera de la lista");
    id = await insertar("projects", { customerId: cliente._id, projectName: "Proyecto Fechas Invertidas", startDate: dia("2026-06-01"), endDate: dia("2026-01-01"), status: "not started", ...sello });
    caso("C05", "projects", id, "rechazado", "fecha de fin antes del inicio");
    id = await insertar("services", { name: "Servicio Costo Texto", unitCost: "45.50", serviceType: "Ensayo de laboratorio", ...sello });
    caso("C06", "services", id, "importado", "costo guardado como texto exacto se convierte");
    id = await insertar("services", { name: "Servicio Costo Inválido", unitCost: "abc", serviceType: "Ensayo de laboratorio", ...sello });
    caso("C07", "services", id, "rechazado", "costo que no es número");
    id = await insertar("employees", { firstName: "Elsa", lastName: "Caso Extra", email: "elsa.caso@example.com", dui: "000000990", employeeCode: "0990",
        departmentId: ana.departmentId, monthlySalary: 700, isActive: true, hasAccess: false, isAdmin: false, notasInternas: "campo fuera del esquema",
        passwordHash: ana.passwordHash, ...sello });
    caso("C08", "employees", id, "importado", "campo fuera del esquema va a datos_extra");
    id = await insertar("employees", { firstName: "Ana", lastName: "Duplicada", email: "ANA.PRUEBA@example.com", dui: "000000991", departmentId: ana.departmentId,
        monthlySalary: 650, isActive: true, passwordHash: ana.passwordHash, ...sello });
    caso("C09", "employees", id, "rechazado", "correo repetido con otras mayúsculas");
    id = await insertar("employees", { firstName: "Fito", lastName: "Clave Plana", email: "fito.caso@example.com", dui: "000000992", departmentId: ana.departmentId,
        monthlySalary: 600, isActive: true, hasAccess: true, passwordHash: "texto-plano", ...sello });
    caso("C10", "employees", id, "advertencia", "contraseña que no es bcrypt: usuario sin contraseña utilizable");
    id = await insertar("contracts", { employeeId: bruno._id, contractType: "Temporal", startDate: dia("2027-01-06"), endDate: dia("2027-06-30"),
        salary: 900, workShiftStart: "8:00 AM", workShiftEnd: "17:00", workShiftHours: 8, clauses: "Hora mal escrita", isActive: false });
    caso("C11", "contracts", id, "rechazado", "hora de entrada que no es HH:MM");
    id = await insertar("contracts", { employeeId: ana._id, contractType: "Temporal", startDate: dia("2026-01-01"), endDate: dia("2026-12-31"),
        salary: 650, workShiftStart: "07:00", workShiftEnd: "15:00", workShiftHours: 8, clauses: "Segundo contrato activo", isActive: true });
    caso("C12", "contracts", id, "rechazado", "segundo contrato activo del mismo empleado");
    const lineaHuerfana = await insertar("payrollentries", { payrollId: new ObjectId(), employeeId: ana._id, baseSalary: 650, netPay: 583.37, ...sello });
    caso("C13", "payrollentries", lineaHuerfana, "rechazado", "planilla inexistente");
    id = await insertar("proformainvoices", { customerId: cliente._id, projectId: proyecto._id, issueDate: dia("2026-10-15"), status: "pending",
        items: [{ _id: new ObjectId(), serviceId: new ObjectId(), quantity: 1, unitCost: 50, subtotal: 50 }],
        overtimeCharges: 0, additionalCharges: 0, projectBaseCost: 0, totalAmount: 50, ...sello });
    caso("C14", "proformainvoices", id, "advertencia", "ítem con servicio inexistente: se importa sin servicio");
    id = await insertar("accountsreceivables", { proformaInvoiceId: proforma._id, invoiceNumber: "F-CASO-C15", issueDate: "13/10/2026", dueDate: "2026-11-12",
        items: [], subtotal: 10, taxAmount: 1.3, totalAmount: 11.3, paidAmount: 5, balanceDue: 6.3, status: "Pending",
        paymentHistory: [{ _id: new ObjectId(), paymentDate: dia("2026-10-14"), amount: 5, method: "Efectivo" }], ...sello });
    caso("C15", "accountsreceivables", id, "rechazado", "fecha de emisión con formato dd/mm/aaaa");
    id = await insertar("accountsreceivables", { proformaInvoiceId: proforma._id, invoiceNumber: "F-CASO-C16", issueDate: "2026-10-16", dueDate: "2026-11-15",
        items: [], subtotal: 20, taxAmount: 2.6, totalAmount: 22.6, paidAmount: 0, balanceDue: 22.6, status: "Pending",
        paymentHistory: [{ _id: new ObjectId(), paymentDate: dia("2026-10-17"), amount: 0, method: "Efectivo", notes: "pago en cero" }], ...sello });
    caso("C16", "accountsreceivables", id, "advertencia", "pago con monto 0: la cuenta entra, el pago se rechaza");
    id = await insertar("overtimerecords", { projectId: proyecto._id, employeeId: ana._id, periodStart: dia("2026-10-12"), periodEnd: dia("2026-10-18"),
        regularHours: 40, overtimeHours: 2, costPerHour: 6.5, totalOvertimePay: 13.123456, overtimeType: "weekly", ...sello });
    caso("C17", "overtimerecords", id, "advertencia", "monto con más de 4 decimales se redondea");
    id = await insertar("weeklyreports", { projectId: proyecto._id, reportedBy: ana._id, weekEnding: new Date("2026-10-09T15:30:00Z"),
        notes: "Fecha con hora", status: "submitted", ...sello });
    caso("C18", "weeklyreports", id, "advertencia", "fecha de día que no está a medianoche UTC");
    id = await insertar("administrators", { name: "Admin", lastName: "Repetido", email: "ana.prueba@example.com", passwordHash: ana.passwordHash, isActive: true, ...sello });
    caso("C19", "administrators", id, "rechazado", "mismo correo que un empleado (no podía iniciar sesión)");
    id = await insertar("departments", { description: "Sin nombre", isActive: "true", ...sello });
    caso("C20", "departments", id, "rechazado", "departamento sin nombre");
    id = await insertar("projects", { customerId: cliente._id, projectName: "Proyecto Técnico Repetido", status: "in progress",
        assignedTechniciansIds: [{ _id: new ObjectId(), technicianId: ana._id }, { _id: new ObjectId(), technicianId: ana._id }], ...sello });
    caso("C21", "projects", id, "advertencia", "técnico asignado dos veces: se importa una sola asignación");
    id = await insertar("payslips", { payrollEntryID: lineaHuerfana, period: "Octubre 2026", salary: 583.37, generatedAt: ahora, sentVia: "email", deliveryStatus: "sent", ...sello });
    caso("C22", "payslips", id, "advertencia", "su línea de planilla fue rechazada: se importa sin línea");
    id = await insertar("customers", { companyName: "Cliente Sin RUC", contactName: "Caso Veintitrés", ...sello });
    caso("C23", "customers", id, "rechazado", "RUC obligatorio");
    id = await insertar("accountsreceivables", { proformaInvoiceId: proforma._id, invoiceNumber: "F-EQUIPO-0001", issueDate: "2026-10-20", dueDate: "2026-11-19",
        items: [], subtotal: 5, taxAmount: 0.65, totalAmount: 5.65, paidAmount: 0, balanceDue: 5.65, status: "Pending", paymentHistory: [], ...sello });
    caso("C25", "accountsreceivables", id, "rechazado", "número de factura repetido");
    id = await insertar("departments", { name: "Departamento Activo Texto", isActive: "true", overtimeHourlyRate: 3, ...sello });
    caso("C26", "departments", id, "importado", "booleano guardado como texto exacto se convierte");
    id = await insertar("customers", { RUC: "CASO-C27", companyName: "Cliente Sin Fechas", contactName: "Caso Veintisiete", email: "sin.fechas@example.com" });
    caso("C27", "customers", id, "advertencia", "sin createdAt: la fecha de creación se toma del ObjectId");
    id = await insertar("auditoria", { evento: "colección que la aplicación no usa", fecha: ahora });
    caso("C28", "auditoria", id, "no_migrado", "colección desconocida: se informa y no se migra");

    const destino = process.env.CASOS_PRUEBA;
    if (destino) fs.writeFileSync(destino, JSON.stringify(casos, null, 2));
    console.log(`Listo: ${casos.length} casos insertados${destino ? ` (lista en ${destino})` : ""}.`);
    await mongoose.disconnect();
}

main().catch((error) => {
    console.error(error);
    process.exit(1);
});
