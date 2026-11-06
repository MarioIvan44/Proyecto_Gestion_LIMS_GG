// Utilidades compartidas por los scripts que arman la copia LOCAL de prueba.
//
// Usan los modelos de Mongoose del backend original (el fork), para que los
// documentos tengan exactamente la forma que les da la aplicación.
import { createRequire } from "node:module";
import path from "node:path";
import { pathToFileURL } from "node:url";

export function forkBackend() {
    const dir = process.env.FORK_BACKEND;
    if (!dir) {
        throw new Error("Define FORK_BACKEND con la ruta a la carpeta backend del fork (JupacaProyecta-PTC-2026/backend).");
    }
    return dir;
}

// Solo se permite trabajar contra un MongoDB local: estos scripts escriben y borran.
export function uriLocal() {
    const uri = process.env.DB_URI;
    if (!uri) throw new Error("Define DB_URI, por ejemplo mongodb://127.0.0.1:27018/jupaca_copia");
    const host = new URL(uri.replace(/^mongodb(\+srv)?:/, "http:")).hostname;
    if (!["127.0.0.1", "localhost", "::1", "[::1]"].includes(host) || uri.startsWith("mongodb+srv:")) {
        throw new Error(`Por seguridad, estos scripts solo corren contra un MongoDB local (recibido: ${host}).`);
    }
    return uri;
}

export async function cargarModelos() {
    const dir = forkBackend();
    const nombres = [
        "administrators", "departments", "employees", "contracts", "customers", "services",
        "projects", "payroll", "payrollEntries", "paylips", "overtimeRecords", "weeklyReports",
        "proformaInvoices", "accountsReceivable",
    ];
    const modelos = {};
    for (const nombre of nombres) {
        const archivo = pathToFileURL(path.join(dir, "src", "models", `${nombre}.js`)).href;
        modelos[nombre] = (await import(archivo)).default;
    }
    return modelos;
}

export function requireDelFork(paquete) {
    return createRequire(path.join(forkBackend(), "package.json"))(paquete);
}

// Medianoche UTC de un día, como guarda la aplicación las fechas «de día».
export const dia = (texto) => new Date(`${texto}T00:00:00.000Z`);
