import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { Hono, type Context } from 'hono';
import { cors } from 'hono/cors';
import {
  distanceMeters,
  kstParts,
  type CalendarEntry,
  type CalendarResponse,
  type CheckinResponse,
  type JoinResponse,
  type Member,
  type SessionResponse,
  type TodayResponse,
  type WorkoutSession,
} from './shared.js';
import type { Config } from './config.js';
import type { Sql } from './db.js';

/** 위치 정확도가 나쁠 때 반경에 더해주는 최대 여유(m). */
const MAX_ACCURACY_SLACK = 50;

/** 위치 튐(지오펜스가 잠깐 나갔다 들어옴)으로 끝난 운동은 이 시간 안에 다시 시작하면 이어붙인다. */
const RESUME_WITHIN_MINUTES = 10;

const hashToken = (t: string) => createHash('sha256').update(t).digest('hex');

const safeEqual = (a: string, b: string) => {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
};

const isCoord = (v: unknown, max: number) =>
  typeof v === 'number' && Number.isFinite(v) && Math.abs(v) <= max;

type SessionRow = { id: number; started_at: Date; ended_at: Date | null };
const toSession = (r: SessionRow): WorkoutSession => ({
  id: r.id,
  startedAt: r.started_at.toISOString(),
  endedAt: r.ended_at ? r.ended_at.toISOString() : null,
});

const secondsBetween = (start: Date, end: Date) =>
  Math.max(0, Math.round((end.getTime() - start.getTime()) / 1000));

export interface Deps {
  sql: Sql;
  config: Config;
  now?: () => Date;
  /** 첫 요청 전에 한 번 실행 (테이블 생성 등) */
  init?: () => Promise<void>;
}

type Env = { Variables: { member: Member } };

export function createApp({ sql, config, now = () => new Date(), init }: Deps) {
  const app = new Hono<Env>();
  app.use('*', cors());

  let ready: Promise<void> | undefined;
  app.use('/api/*', async (_c, next) => {
    if (init) {
      ready ??= init().catch((e) => {
        ready = undefined; // 실패하면 다음 요청에서 재시도
        throw e;
      });
      await ready;
    }
    await next();
  });

  // DB 연결까지 확인하는 헬스체크
  app.get('/api/health', async (c) => {
    await sql`SELECT 1`;
    return c.json({ ok: true });
  });

  // 가입 (또는 같은 이름으로 재로그인 → 토큰 재발급, 이전 기기는 로그아웃)
  app.post('/api/join', async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const name = typeof body.name === 'string' ? body.name.trim() : '';
    const code = typeof body.code === 'string' ? body.code.trim() : '';
    if (!safeEqual(code, config.groupCode)) return c.json({ error: '가입 코드가 틀렸어요.' }, 403);
    if (name.length < 1 || name.length > 20) return c.json({ error: '이름은 1~20자로 입력해주세요.' }, 400);

    const token = randomBytes(24).toString('base64url');
    const tokenHash = hashToken(token);

    const [existing] = await sql<Member[]>`SELECT id, name FROM members WHERE name = ${name}`;
    if (existing) {
      await sql`UPDATE members SET token_hash = ${tokenHash} WHERE id = ${existing.id}`;
      return c.json<JoinResponse>({ token, member: existing });
    }
    const [{ count }] = await sql<{ count: number }[]>`SELECT count(*)::int AS count FROM members`;
    if (count >= config.maxMembers) {
      return c.json({ error: `멤버는 최대 ${config.maxMembers}명이에요.` }, 403);
    }
    const [member] = await sql<Member[]>`
      INSERT INTO members (name, token_hash) VALUES (${name}, ${tokenHash}) RETURNING id, name`;
    return c.json<JoinResponse>({ token, member }, 201);
  });

  // 이하 인증 필요
  app.use('/api/*', async (c, next) => {
    if (c.req.path === '/api/health' || c.req.path === '/api/join') return next();
    const token = c.req.header('authorization')?.replace(/^Bearer\s+/i, '');
    if (!token) return c.json({ error: '로그인이 필요해요.' }, 401);
    const [member] = await sql<Member[]>`
      SELECT id, name FROM members WHERE token_hash = ${hashToken(token)}`;
    if (!member) return c.json({ error: '로그인이 만료됐어요. 다시 가입해주세요.' }, 401);
    c.set('member', member);
    await next();
  });

  app.get('/api/me', (c) => c.json(c.get('member')));

  /** 종료를 놓친 오래된 운동을 started_at + maxSessionHours 로 닫는다. */
  const closeStaleSessions = (at: Date) => sql`
    UPDATE sessions
    SET ended_at = started_at + make_interval(hours => ${config.maxSessionHours}), end_source = 'timeout'
    WHERE ended_at IS NULL AND started_at < ${at}::timestamptz - make_interval(hours => ${config.maxSessionHours})`;

  /** 보낸 좌표가 헬스장 반경 안인지. 아니면 에러 메시지. */
  const checkLocation = (body: Record<string, unknown>): { ok: true } | { ok: false; error: string } => {
    if (!isCoord(body.latitude, 90) || !isCoord(body.longitude, 180)) {
      return { ok: false, error: '위치 정보가 필요해요. 위치 권한을 확인해주세요.' };
    }
    const dist = distanceMeters(config.gym, { latitude: body.latitude as number, longitude: body.longitude as number });
    const accuracy = typeof body.accuracy === 'number' && body.accuracy > 0 ? body.accuracy : 0;
    if (dist > config.gym.radiusMeters + Math.min(accuracy, MAX_ACCURACY_SLACK)) {
      return { ok: false, error: `헬스장에서 ${Math.round(dist)}m 떨어져 있어요. 헬스장에서 시작해주세요.` };
    }
    return { ok: true };
  };

  /** 입실(=출석, 운동 시작). 이미 운동 중이면 그대로 돌려준다. */
  const startSession = async (memberId: number, source: 'manual' | 'geofence', at: Date) => {
    await closeStaleSessions(at);

    const [open] = await sql<SessionRow[]>`
      SELECT id, started_at, ended_at FROM sessions WHERE member_id = ${memberId} AND ended_at IS NULL`;
    if (open) return { session: toSession(open), unchanged: true };

    // 자동 퇴실 직후 다시 들어온 거면 이전 운동을 이어간다
    const [resumed] = await sql<SessionRow[]>`
      UPDATE sessions SET ended_at = NULL, end_source = NULL
      WHERE id = (
        SELECT id FROM sessions
        WHERE member_id = ${memberId} AND end_source = 'geofence'
          AND ended_at > ${at}::timestamptz - make_interval(mins => ${RESUME_WITHIN_MINUTES})
        ORDER BY ended_at DESC LIMIT 1
      )
      RETURNING id, started_at, ended_at`;
    if (resumed) return { session: toSession(resumed), unchanged: false };

    const [created] = await sql<SessionRow[]>`
      INSERT INTO sessions (member_id, started_at, start_source)
      VALUES (${memberId}, ${at}, ${source})
      ON CONFLICT (member_id) WHERE ended_at IS NULL DO NOTHING
      RETURNING id, started_at, ended_at`;
    if (created) return { session: toSession(created), unchanged: false };

    // 동시에 시작 요청이 두 번 온 경우
    const [raced] = await sql<SessionRow[]>`
      SELECT id, started_at, ended_at FROM sessions WHERE member_id = ${memberId} AND ended_at IS NULL`;
    return { session: raced ? toSession(raced) : null, unchanged: true };
  };

  const readBody = async (c: Context) => ((await c.req.json().catch(() => ({}))) ?? {}) as Record<string, unknown>;

  // 입실 = 출석 + 운동 시작.
  // 지오펜스 진입은 그 자체가 위치 증명이라 좌표 검사 없이, 수동 시작은 헬스장 반경 안인지 확인한다.
  app.post('/api/sessions/start', async (c) => {
    const body = await readBody(c);
    const source = body.source === 'geofence' ? 'geofence' : 'manual';
    if (source === 'manual') {
      const loc = checkLocation(body);
      if (!loc.ok) return c.json({ error: loc.error }, 400);
    }
    return c.json<SessionResponse>(await startSession(c.get('member').id, source, now()));
  });

  // 퇴실 = 운동 종료. 위치와 상관없이 가능.
  app.post('/api/sessions/end', async (c) => {
    const me = c.get('member');
    const body = await readBody(c);
    const source = body.source === 'geofence' ? 'geofence' : 'manual';
    const at = now();
    await closeStaleSessions(at);
    const [ended] = await sql<SessionRow[]>`
      UPDATE sessions SET ended_at = GREATEST(${at}::timestamptz, started_at), end_source = ${source}
      WHERE member_id = ${me.id} AND ended_at IS NULL
      RETURNING id, started_at, ended_at`;
    return c.json<SessionResponse>({ session: ended ? toSession(ended) : null, unchanged: !ended });
  });

  // 예전 앱(빌드 4 이하) 호환: 출석 체크 = 위치 확인 후 입실
  app.post('/api/checkin', async (c) => {
    const body = await readBody(c);
    const loc = checkLocation(body);
    if (!loc.ok) return c.json({ error: loc.error }, 400);
    const at = now();
    const res = await startSession(c.get('member').id, body.source === 'geofence' ? 'geofence' : 'manual', at);
    return c.json<CheckinResponse>({
      date: kstParts(at).date,
      checkedInAt: res.session?.startedAt ?? at.toISOString(),
      alreadyCheckedIn: res.unchanged,
      distanceMeters: 0,
    });
  });

  /** KST 날짜 범위 [from, to) 의 운동 기록을 날짜별·멤버별로 묶는다. */
  const sessionsByDay = async (from: string, to: string, at: Date) => {
    const rows = await sql<{ member_id: number; date: string; started_at: Date; ended_at: Date | null }[]>`
      SELECT member_id, (started_at AT TIME ZONE 'Asia/Seoul')::date::text AS date, started_at, ended_at
      FROM sessions
      WHERE (started_at AT TIME ZONE 'Asia/Seoul') >= ${from}::date
        AND (started_at AT TIME ZONE 'Asia/Seoul') < ${to}::date
      ORDER BY started_at`;
    const days: Record<string, CalendarEntry[]> = {};
    for (const r of rows) {
      const list = (days[r.date] ??= []);
      let e = list.find((x) => x.memberId === r.member_id);
      if (!e) {
        // 그날 첫 입실 = 출석 시각
        e = { memberId: r.member_id, attendedAt: r.started_at.toISOString(), seconds: 0, sessions: [] };
        list.push(e);
      }
      e.seconds += secondsBetween(r.started_at, r.ended_at ?? at);
      e.sessions.push({ startedAt: r.started_at.toISOString(), endedAt: r.ended_at?.toISOString() ?? null });
    }
    for (const list of Object.values(days)) list.sort((a, b) => a.memberId - b.memberId);
    return days;
  };

  app.get('/api/calendar', async (c) => {
    const at = now();
    const param = c.req.query('month') ?? '';
    const month = /^\d{4}-(0[1-9]|1[0-2])$/.test(param) ? param : kstParts(at).date.slice(0, 7);
    await closeStaleSessions(at);
    const [{ next }] = await sql<{ next: string }[]>`
      SELECT (${`${month}-01`}::date + interval '1 month')::date::text AS next`;
    const members = await sql<Member[]>`SELECT id, name FROM members ORDER BY id`;
    const days = await sessionsByDay(`${month}-01`, next, at);
    return c.json<CalendarResponse>({ month, members, days });
  });

  app.get('/api/today', async (c) => {
    const at = now();
    const { date } = kstParts(at);
    await closeStaleSessions(at);
    const [{ tomorrow }] = await sql<{ tomorrow: string }[]>`
      SELECT (${date}::date + 1)::text AS tomorrow`;
    const members = await sql<Member[]>`SELECT id, name FROM members ORDER BY id`;
    const entries = (await sessionsByDay(date, tomorrow, at))[date] ?? [];
    // 자정을 넘겨 진행 중인 운동도 '운동 중'으로 보이도록 따로 조회
    const open = await sql<{ member_id: number; started_at: Date }[]>`
      SELECT member_id, started_at FROM sessions WHERE ended_at IS NULL`;
    return c.json<TodayResponse>({
      date,
      // 예전 앱(빌드 3 이하)이 이 필드를 읽어서 남겨둔다
      window: { startHour: 0, endHour: 24 },
      gym: config.gym,
      members: members.map((m) => {
        const e = entries.find((x) => x.memberId === m.id);
        return {
          id: m.id,
          name: m.name,
          checkedInAt: e?.attendedAt ?? null,
          activeSince: open.find((o) => o.member_id === m.id)?.started_at.toISOString() ?? null,
          seconds: e?.seconds ?? 0,
          visits: e?.sessions.length ?? 0,
        };
      }),
    });
  });

  app.onError((err, c) => {
    console.error(err);
    return c.json({ error: '서버 오류가 발생했어요.' }, 500);
  });

  return app;
}
