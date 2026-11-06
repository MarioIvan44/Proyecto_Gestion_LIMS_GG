// Crea en un MongoDB LOCAL los datos «del equipo» (sin marca de demostración)
// que necesita seedShowcase para generar su historial: departamentos de los
// cuatro tipos, servicios con costo, empleados con contrato, clientes y proyectos.
// Todos los datos son inventados y los correos son @example.com.
//
// Uso (desde backend/migracion/copia_prueba):
//   FORK_BACKEND=<ruta>/JupacaProyecta-PTC-2026/backend \
//   DB_URI=mongodb://127.0.0.1:27018/jupaca_copia \
//   CREDENCIALES_PRUEBA=<archivo fuera del repo> \
//   node crear_base.mjs [--reiniciar]
//
// --reiniciar borra la base local completa antes de crear los datos.
import crypto from "node:crypto";
import fs from "node:fs";

import { cargarModelos, dia, requireDelFork, uriLocal } from "./comun.mjs";

const bcrypt = requireDelFork("bcryptjs");

async function main() {
    const uri = uriLocal();
    const m = await cargarModelos();
    const mongoose = m.customers.base;
    await mongoose.connect(uri);
    console.log(`Conectado a la base local "${mongoose.connection.name}"`);

    if (process.argv.includes("--reiniciar")) {
        await mongoose.connection.dropDatabase();
        console.log("Base local borrada (--reiniciar)");
    }
    // Crea los índices que la aplicación declara (RUC y correo únicos, etc.).
    for (const modelo of Object.values(m)) await modelo.init();

    if (await m.departments.countDocuments() > 0) {
        console.log("La base ya tiene datos base; usa --reiniciar para empezar de cero.");
        await mongoose.disconnect();
        return;
    }

    const clave = crypto.randomBytes(9).toString("base64url");
    const hash = (texto) => bcrypt.hashSync(texto, 10);

    await m.administrators.create({
        name: "Administración", lastName: "Prueba", email: "admin.prueba@example.com",
        passwordHash: hash(clave), isVerified: true, loginAttempts: 0, isActive: true,
    });

    const [lab, admin, ing, cons] = await m.departments.create([
        { name: "Laboratorio de suelos", description: "Ensayos de laboratorio", isActive: true, overtimeHourlyRate: 3.25 },
        { name: "Administración", description: "Finanzas y recursos humanos", isActive: true, overtimeHourlyRate: 4.1 },
        { name: "Ingeniería", description: "Diseño y supervisión", isActive: true, overtimeHourlyRate: 6.5 },
        { name: "Construcción", description: "Cuadrillas de obra", isActive: true, overtimeHourlyRate: 2.8 },
    ]);

    const servicios = await m.services.create([
        { name: "Sondeo SPT", description: "Perforación con ensayo de penetración estándar", unitCost: 85, serviceType: "Visita de campo" },
        { name: "Visita técnica", description: "Inspección en sitio", unitCost: 60, serviceType: "Visita de campo" },
        { name: "Granulometría", description: "Análisis granulométrico por tamizado", unitCost: 35.5, serviceType: "Ensayo de laboratorio" },
        { name: "Límites de Atterberg", description: "Límite líquido y plástico", unitCost: 42.75, serviceType: "Ensayo de laboratorio" },
        { name: "Informe geotécnico", description: "Redacción del informe final", unitCost: 450, serviceType: "Servicio profesional" },
        { name: "Supervisión de obra", description: "Supervisión por jornada", unitCost: 120, serviceType: "Servicio profesional" },
    ]);

    const personas = [
        { firstName: "Ana", lastName: "Prueba Laboratorio", dep: lab, salary: 650, job: "Laboratorista", afp: "Confía" },
        { firstName: "Bruno", lastName: "Prueba Oficina", dep: admin, salary: 900, job: "Contador", afp: "Crecer", hasAccess: true },
        { firstName: "Carla", lastName: "Prueba Ingeniería", dep: ing, salary: 1500, job: "Ingeniera civil", afp: "Confía", isAdmin: true, hasAccess: true },
        { firstName: "Diego", lastName: "Prueba Obra", dep: cons, salary: 520, job: "Albañil", afp: "Crecer" },
    ];
    const empleados = [];
    for (const [i, p] of personas.entries()) {
        const empleado = await m.employees.create({
            firstName: p.firstName, lastName: p.lastName,
            phone: `7000000${i + 1}`, email: `${p.firstName.toLowerCase()}.prueba@example.com`,
            dui: `0000000${i + 1}0`, employeeCode: String(i + 1).padStart(4, "0"),
            employeeType: "Permanente", departmentId: p.dep._id, jobTitle: p.job,
            bankAccount: `10000000${i + 1}`, accountType: "Ahorro", afp: p.afp,
            isPensioner: false, isUnderJudicialProcess: false, workShiftHours: 8,
            hireDate: dia("2025-01-06"), monthlySalary: p.salary,
            passwordHash: hash(clave), isActive: true, isAdmin: Boolean(p.isAdmin),
            hasAccess: Boolean(p.hasAccess), isVerified: Boolean(p.hasAccess), loginAttempts: 0,
        });
        empleados.push(empleado);
        await m.contracts.create({
            employeeId: empleado._id, contractType: "Indefinido",
            startDate: dia("2025-01-06"), endDate: dia("2027-01-05"), salary: p.salary,
            workShiftStart: "07:30", workShiftEnd: "16:30", workShiftHours: 8,
            clauses: "Contrato de prueba con datos inventados.", isActive: true,
        });
    }

    const [cliente1, cliente2] = await m.customers.create([
        { RUC: "0614-010180-101-1", companyName: "Constructora Ejemplo S.A. de C.V.", contactName: "Elena Ejemplo",
          phone: "22000001", email: "compras@constructora.example.com", address: "San Salvador", additionalNotes: "Cliente de prueba" },
        { RUC: "0614-020290-102-2", companyName: "Desarrollos de Prueba S.A.", contactName: "Fabio Ejemplo",
          phone: "22000002", email: "contacto@desarrollos.example.com", address: "Santa Tecla" },
    ]);

    await m.projects.create([
        { customerId: cliente1._id, projectName: "Edificio Ejemplo Norte", projectCode: "EEN-01",
          startDate: dia("2026-02-02"), endDate: dia("2026-12-18"), description: "Estudio de suelos para edificio de 6 niveles",
          baseCost: 12500, dayTimeOverTimeCost: 6.5, nightTimeOverTimeCost: 8.75, status: "in progress",
          assignedTechniciansIds: [{ technicianId: empleados[0]._id }, { technicianId: empleados[3]._id }],
          supervisorEngineer: "Carla Prueba Ingeniería", projectProgress: [] },
        { customerId: cliente2._id, projectName: "Bodega de Prueba Sur", projectCode: "BPS-01",
          startDate: dia("2025-05-05"), endDate: dia("2025-09-30"), description: "Sondeos para bodega industrial",
          baseCost: 7800, dayTimeOverTimeCost: 5, nightTimeOverTimeCost: 7.5, status: "completed",
          assignedTechniciansIds: [{ technicianId: empleados[0]._id }],
          supervisorEngineer: "Carla Prueba Ingeniería", projectProgress: [] },
    ]);

    // Una planilla «del equipo» en un mes del historial: seedShowcase le agrega
    // filas de empleados de demostración y guarda el total original en
    // seedOriginalTotal. Sirve para probar que la migración lo detecta.
    const planilla = await m.payroll.create({
        departmentId: lab._id, periodStart: dia("2026-03-01"), periodEnd: dia("2026-03-31"),
        generatedBy: empleados[1]._id, totalAmount: 583.37, status: "paid",
        generatedAt: new Date("2026-03-31T22:15:00.000Z"), includeDeductions: true, includeBonuses: false,
    });
    await m.payrollEntries.create({
        payrollId: planilla._id, employeeId: empleados[0]._id, baseSalary: 650, workingDays: 30, shiftHours: 8,
        dailyRateBasis: "month30", earnedSalary: 650, grossEarnings: 650, isssDeduction: 19.5, afpDeduction: 47.13,
        netBeforeRent: 583.37, rentDeduction: 0, deductions: 66.63, netPay: 583.37,
    });

    const destino = process.env.CREDENCIALES_PRUEBA;
    if (destino) {
        fs.writeFileSync(destino, JSON.stringify({ email: "admin.prueba@example.com", password: clave,
            empleados: empleados.map((e) => e.email), nota: "Misma contraseña para todos; datos inventados." }, null, 2));
        console.log(`Credenciales de prueba guardadas en ${destino}`);
    }
    console.log(`Listo: 1 administrador, 4 departamentos, ${servicios.length} servicios, 4 empleados con contrato, 2 clientes, 2 proyectos.`);
    await mongoose.disconnect();
}

main().catch(async (error) => {
    console.error(error);
    process.exit(1);
});
