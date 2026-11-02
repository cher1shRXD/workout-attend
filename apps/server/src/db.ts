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
  await sql`
    CREATE TABLE IF NOT EXISTS sessions (
      id            SERIAL PRIMARY KEY,
      member_id     INTEGER NOT NULL REFERENCES members(id) ON DELETE CASCADE,
      started_at    TIMESTAMPTZ NOT NULL,
      ended_at      TIMESTAMPTZ,
      start_source  TEXT NOT NULL,
      end_source    TEXT
    )`;
  // 멤버당 진행 중인 운동은 하나만
  await sql`CREATE UNIQUE INDEX IF NOT EXISTS sessions_one_open ON sessions (member_id) WHERE ended_at IS NULL`;
  await sql`CREATE INDEX IF NOT EXISTS sessions_started ON sessions (started_at)`;
}
