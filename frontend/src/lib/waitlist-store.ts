import "server-only";
import { promises as fs } from "node:fs";
import path from "node:path";
import postgres from "postgres";

export type Role = "trader" | "lp" | "both";
export type Signup = { email: string; role: Role; source: string | null; createdAt: string };

export interface WaitlistStore {
  /** Returns false when the email was already on the list. */
  add(s: { email: string; role: Role; source: string | null; ipHash: string | null }): Promise<boolean>;
  count(): Promise<number>;
  all(): Promise<Signup[]>;
}

// ---------------------------------------------------------------------------
// Postgres (production): any DATABASE_URL works (Neon, Supabase, Vercel Postgres, RDS...)
// ---------------------------------------------------------------------------

class PostgresStore implements WaitlistStore {
  private sql: postgres.Sql;
  private ready: Promise<unknown>;

  constructor(url: string) {
    this.sql = postgres(url, { max: 3, idle_timeout: 20, prepare: false });
    // Same DDL as db/schema.sql, applied idempotently on first use.
    this.ready = this.sql`
      CREATE TABLE IF NOT EXISTS waitlist (
        id          BIGSERIAL PRIMARY KEY,
        email       TEXT NOT NULL UNIQUE,
        role        TEXT NOT NULL CHECK (role IN ('trader', 'lp', 'both')),
        source      TEXT,
        ip_hash     TEXT,
        created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
      )`;
  }

  async add(s: { email: string; role: Role; source: string | null; ipHash: string | null }) {
    await this.ready;
    const rows = await this.sql`
      INSERT INTO waitlist (email, role, source, ip_hash)
      VALUES (${s.email}, ${s.role}, ${s.source}, ${s.ipHash})
      ON CONFLICT (email) DO NOTHING
      RETURNING id`;
    return rows.length > 0;
  }

  async count() {
    await this.ready;
    const [row] = await this.sql<{ n: string }[]>`SELECT count(*)::text AS n FROM waitlist`;
    return Number(row.n);
  }

  async all() {
    await this.ready;
    const rows = await this.sql<{ email: string; role: Role; source: string | null; created_at: Date }[]>`
      SELECT email, role, source, created_at FROM waitlist ORDER BY created_at ASC`;
    return rows.map((r) => ({ email: r.email, role: r.role, source: r.source, createdAt: r.created_at.toISOString() }));
  }
}

// ---------------------------------------------------------------------------
// JSON file (local development only: serverless filesystems are ephemeral)
// ---------------------------------------------------------------------------

class FileStore implements WaitlistStore {
  private file = path.join(process.cwd(), ".data", "waitlist.json");
  private lock: Promise<unknown> = Promise.resolve();

  private async read(): Promise<Signup[]> {
    try {
      return JSON.parse(await fs.readFile(this.file, "utf8")) as Signup[];
    } catch {
      return [];
    }
  }

  async add(s: { email: string; role: Role; source: string | null }) {
    const op = this.lock.then(async () => {
      const list = await this.read();
      if (list.some((x) => x.email === s.email)) return false;
      list.push({ email: s.email, role: s.role, source: s.source, createdAt: new Date().toISOString() });
      await fs.mkdir(path.dirname(this.file), { recursive: true });
      await fs.writeFile(this.file, JSON.stringify(list, null, 2));
      return true;
    });
    this.lock = op.catch(() => undefined);
    return op;
  }

  async count() {
    return (await this.read()).length;
  }

  async all() {
    return this.read();
  }
}

let store: WaitlistStore | null = null;

export function getStore(): WaitlistStore {
  if (!store) {
    const url = process.env.DATABASE_URL;
    if (url) store = new PostgresStore(url);
    else {
      if (process.env.NODE_ENV === "production") {
        console.warn("DATABASE_URL is not set: waitlist signups are stored in .data/waitlist.json");
      }
      store = new FileStore();
    }
  }
  return store;
}
