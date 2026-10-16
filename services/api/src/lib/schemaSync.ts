import { PrismaClient, Prisma } from "@prisma/client";

export interface SchemaSyncResult {
  inSync: boolean;
  missingInClient: string[];
  missingInDb: string[];
}

export async function checkSchemaSync(
  client: Pick<PrismaClient, "$queryRawUnsafe">,
  dmmf: typeof Prisma.dmmf = Prisma.dmmf
): Promise<SchemaSyncResult> {
  const rows = await client.$queryRawUnsafe<Array<{ table_name: string; column_name: string }>>(
    "SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = 'public'"
  );

  const dbTableColumns = new Map<string, Set<string>>();
  for (const row of rows) {
    let cols = dbTableColumns.get(row.table_name);
    if (!cols) {
      cols = new Set<string>();
      dbTableColumns.set(row.table_name, cols);
    }
    cols.add(row.column_name);
  }

  const missingInClient: string[] = [];
  const missingInDb: string[] = [];

  for (const m of dmmf.datamodel.models) {
    const tableName = m.dbName || m.name;
    const dbCols = dbTableColumns.get(tableName);
    const scalarFields = m.fields.filter((f) => f.kind === "scalar" || f.kind === "enum");
    const expectedCols = new Set(scalarFields.map((f) => f.dbName || f.name));

    if (!dbCols) {
      for (const col of expectedCols) {
        missingInDb.push(`${tableName}.${col}`);
      }
    } else {
      for (const col of expectedCols) {
        if (!dbCols.has(col)) {
          missingInDb.push(`${tableName}.${col}`);
        }
      }
      for (const col of dbCols) {
        if (!expectedCols.has(col)) {
          missingInClient.push(`${tableName}.${col}`);
        }
      }
    }
  }

  return {
    inSync: missingInClient.length === 0 && missingInDb.length === 0,
    missingInClient,
    missingInDb,
  };
}

export async function assertPrismaClientInSync(
  client: Pick<PrismaClient, "$queryRawUnsafe">,
  dmmf: typeof Prisma.dmmf = Prisma.dmmf
): Promise<void> {
  if (process.env.SKIP_PRISMA_SYNC_CHECK === "1") return;
  const result = await checkSchemaSync(client, dmmf);
  if (!result.inSync) {
    const details: string[] = [];
    if (result.missingInClient.length > 0) {
      details.push(
        `Prisma client is out of date: database columns [${result.missingInClient.join(", ")}] are missing in client.\n` +
          `Run 'pnpm exec prisma generate' to regenerate the client.`
      );
    }
    if (result.missingInDb.length > 0) {
      details.push(
        `Database schema is out of date: client fields [${result.missingInDb.join(", ")}] are missing in database.\n` +
          `Run 'pnpm exec prisma migrate deploy' to apply pending migrations.`
      );
    }
    throw new Error(`[SchemaDrift] Database schema and Prisma client are out of sync!\n${details.join("\n")}`);
  }
}
