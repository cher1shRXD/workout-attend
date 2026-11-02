import postgres from 'postgres';

export type Sql = postgres.Sql;

/**
 * DATABASE_URL(또는 Vercel-Neon 연동이 넣어주는 POSTGRES_URL)로 접속.
 * Neon 풀러(pgbouncer, transaction 모드)에서도 동작하도록 prepared statement 는 끈다.
 */
export function connect(url = process.env.DATABASE_URL ?? process.env.POSTGRES_URL): Sql {
  const opts = { max: 3, prepare: false, idle_timeout: 20, onnotice: () => {} };
  return url ? postgres(url, opts) : postgres(opts);
}

export async function migrate(sql: Sql) {
  await sql`
    CREATE TABLE IF NOT EXISTS members (
      id          SERIAL PRIMARY KEY,
      name        TEXT NOT NULL UNIQUE,
      token_hash  TEXT NOT NULL UNIQUE,
      push_token  TEXT,
      push_env    TEXT NOT NULL DEFAULT 'production',
      created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
    )`;
  await sql`
    CREATE TABLE IF NOT EXISTS attendance (
      member_id      INTEGER NOT NULL REFERENCES members(id) ON DELETE CASCADE,
      date           DATE NOT NULL,
      checked_in_at  TIMESTAMPTZ NOT NULL,
      source         TEXT NOT NULL,
      distance_m     INTEGER NOT NULL,
      PRIMARY KEY (member_id, date)
    )`;
  await sql`ALTER TABLE members ADD COLUMN IF NOT EXISTS push_env TEXT NOT NULL DEFAULT 'production'`;
}
