import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { Hono } from 'hono';
import { cors } from 'hono/cors';
import {
  distanceMeters,
  kstParts,
  type CheckinRequest,
  type CalendarEntry,
  type CalendarResponse,
  type CheckinResponse,
  type HistoryResponse,
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

const hashToken = (t: string) => createHash('sha256').update(t).digest('hex');

const safeEqual = (a: string, b: string) => {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
};

/** 위치 튐(지오펜스가 잠깐 나갔다 들어옴)으로 끝난 운동은 이 시간 안에 다시 시작하면 이어붙인다. */
const RESUME_WITHIN_MINUTES = 10;

type SessionRow = { id: number; started_at: Date; ended_at: Date | null };
const toSession = (r: SessionRow): WorkoutSession => ({
  id: r.id,
  startedAt: r.started_at.toISOString(),
  endedAt: r.ended_at ? r.ended_at.toISOString() : null,
});

const isCoord = (v: unknown, max: number) =>
  typeof v === 'number' && Number.isFinite(v) && Math.abs(v) <= max;

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

  app.post('/api/checkin', async (c) => {
    const me = c.get('member');
    const body = (await c.req.json().catch(() => ({}))) as Partial<CheckinRequest>;
    if (!isCoord(body.latitude, 90) || !isCoord(body.longitude, 180)) {
      return c.json({ error: '위치 정보가 올바르지 않아요.' }, 400);
    }
    const source = body.source === 'geofence' ? 'geofence' : 'manual';
    const at = now();
    const { date, hour } = kstParts(at);
    const { morningStartHour: start, morningEndHour: end, gym } = config;

    if (hour < start || hour >= end) {
      return c.json({ error: `아침 출석은 ${start}시~${end}시 사이에만 인정돼요.` }, 400);
    }

    const dist = distanceMeters(gym, { latitude: body.latitude!, longitude: body.longitude! });
    const accuracy = typeof body.accuracy === 'number' && body.accuracy > 0 ? body.accuracy : 0;
    if (dist > gym.radiusMeters + Math.min(accuracy, MAX_ACCURACY_SLACK)) {
      return c.json({ error: `헬스장에서 ${Math.round(dist)}m 떨어져 있어요.`, distanceMeters: dist }, 400);
    }

    const inserted = await sql<{ checked_in_at: Date }[]>`
      INSERT INTO attendance (member_id, date, checked_in_at, source, distance_m)
      VALUES (${me.id}, ${date}, ${at}, ${source}, ${Math.round(dist)})
      ON CONFLICT (member_id, date) DO NOTHING
      RETURNING checked_in_at`;

    if (inserted.length > 0) {
      return c.json<CheckinResponse>({
        date,
        checkedInAt: at.toISOString(),
        alreadyCheckedIn: false,
        distanceMeters: Math.round(dist),
      });
    }

    const [row] = await sql<{ checked_in_at: Date; distance_m: number }[]>`
      SELECT checked_in_at, distance_m FROM attendance WHERE member_id = ${me.id} AND date = ${date}`;
    return c.json<CheckinResponse>({
      date,
      checkedInAt: row.checked_in_at.toISOString(),
      alreadyCheckedIn: true,
      distanceMeters: row.distance_m,
    });
  });

  /** 종료를 놓친 오래된 운동을 started_at + maxSessionHours 로 닫는다. */
  const closeStaleSessions = (at: Date) => sql`
    UPDATE sessions
    SET ended_at = started_at + make_interval(hours => ${config.maxSessionHours}), end_source = 'timeout'
    WHERE ended_at IS NULL AND started_at < ${at}::timestamptz - make_interval(hours => ${config.maxSessionHours})`;

  app.post('/api/sessions/start', async (c) => {
    const me = c.get('member');
    const body = await c.req.json().catch(() => ({}));
    const source = body.source === 'geofence' ? 'geofence' : 'manual';
    const at = now();
    await closeStaleSessions(at);

    const [open] = await sql<SessionRow[]>`
      SELECT id, started_at, ended_at FROM sessions WHERE member_id = ${me.id} AND ended_at IS NULL`;
    if (open) return c.json<SessionResponse>({ session: toSession(open), unchanged: true });

    // 자동 종료 직후 다시 들어온 거면 이전 운동을 이어간다
    const [resumed] = await sql<SessionRow[]>`
      UPDATE sessions SET ended_at = NULL, end_source = NULL
      WHERE id = (
        SELECT id FROM sessions
        WHERE member_id = ${me.id} AND end_source = 'geofence'
          AND ended_at > ${at}::timestamptz - make_interval(mins => ${RESUME_WITHIN_MINUTES})
        ORDER BY ended_at DESC LIMIT 1
      )
      RETURNING id, started_at, ended_at`;
    if (resumed) return c.json<SessionResponse>({ session: toSession(resumed), unchanged: false });

    const [created] = await sql<SessionRow[]>`
      INSERT INTO sessions (member_id, started_at, start_source)
      VALUES (${me.id}, ${at}, ${source})
      ON CONFLICT (member_id) WHERE ended_at IS NULL DO NOTHING
      RETURNING id, started_at, ended_at`;
    if (created) return c.json<SessionResponse>({ session: toSession(created), unchanged: false });

    // 동시에 시작 요청이 두 번 온 경우
    const [raced] = await sql<SessionRow[]>`
      SELECT id, started_at, ended_at FROM sessions WHERE member_id = ${me.id} AND ended_at IS NULL`;
    return c.json<SessionResponse>({ session: raced ? toSession(raced) : null, unchanged: true });
  });

  app.post('/api/sessions/end', async (c) => {
    const me = c.get('member');
    const body = await c.req.json().catch(() => ({}));
    const source = body.source === 'geofence' ? 'geofence' : 'manual';
    const at = now();
    await closeStaleSessions(at);
    const [ended] = await sql<SessionRow[]>`
      UPDATE sessions SET ended_at = GREATEST(${at}::timestamptz, started_at), end_source = ${source}
      WHERE member_id = ${me.id} AND ended_at IS NULL
      RETURNING id, started_at, ended_at`;
    return c.json<SessionResponse>({ session: ended ? toSession(ended) : null, unchanged: !ended });
  });

  app.get('/api/calendar', async (c) => {
    const at = now();
    const param = c.req.query('month') ?? '';
    const month = /^\d{4}-(0[1-9]|1[0-2])$/.test(param) ? param : kstParts(at).date.slice(0, 7);
    const first = `${month}-01`;
    await closeStaleSessions(at);

    const members = await sql<Member[]>`SELECT id, name FROM members ORDER BY id`;
    const attendance = await sql<{ member_id: number; date: string; checked_in_at: Date }[]>`
      SELECT member_id, date::text AS date, checked_in_at FROM attendance
      WHERE date >= ${first}::date AND date < ${first}::date + interval '1 month'`;
    const sessions = await sql<{ member_id: number; date: string; started_at: Date; ended_at: Date | null }[]>`
      SELECT member_id, (started_at AT TIME ZONE 'Asia/Seoul')::date::text AS date, started_at, ended_at
      FROM sessions
      WHERE (started_at AT TIME ZONE 'Asia/Seoul') >= ${first}::date
        AND (started_at AT TIME ZONE 'Asia/Seoul') < ${first}::date + interval '1 month'
      ORDER BY started_at`;

    const days: Record<string, CalendarEntry[]> = {};
    const entry = (date: string, memberId: number) => {
      const list = (days[date] ??= []);
      let e = list.find((x) => x.memberId === memberId);
      if (!e) list.push((e = { memberId, attendedAt: null, seconds: 0, sessions: [] }));
      return e;
    };
    for (const a of attendance) entry(a.date, a.member_id).attendedAt = a.checked_in_at.toISOString();
    for (const s of sessions) {
      const e = entry(s.date, s.member_id);
      const end = s.ended_at ?? at;
      e.seconds += Math.max(0, Math.round((end.getTime() - s.started_at.getTime()) / 1000));
      e.sessions.push({ startedAt: s.started_at.toISOString(), endedAt: s.ended_at?.toISOString() ?? null });
    }
    for (const list of Object.values(days)) list.sort((a, b) => a.memberId - b.memberId);
    return c.json<CalendarResponse>({ month, members, days });
  });

  app.get('/api/today', async (c) => {
    const at = now();
    const { date } = kstParts(at);
    await closeStaleSessions(at);
    const rows = await sql<{ id: number; name: string; checked_in_at: Date | null; active_since: Date | null }[]>`
      SELECT m.id, m.name, a.checked_in_at, s.started_at AS active_since
      FROM members m
      LEFT JOIN attendance a ON a.member_id = m.id AND a.date = ${date}
      LEFT JOIN sessions s ON s.member_id = m.id AND s.ended_at IS NULL
      ORDER BY m.id`;
    return c.json<TodayResponse>({
      date,
      window: { startHour: config.morningStartHour, endHour: config.morningEndHour },
      gym: config.gym,
      members: rows.map((r) => ({
        id: r.id,
        name: r.name,
        checkedInAt: r.checked_in_at ? r.checked_in_at.toISOString() : null,
        activeSince: r.active_since ? r.active_since.toISOString() : null,
      })),
    });
  });

  app.get('/api/history', async (c) => {
    const days = Math.min(Math.max(Number(c.req.query('days')) || 14, 1), 60);
    const today = now();
    const dates = Array.from({ length: days }, (_, i) =>
      kstParts(new Date(today.getTime() - i * 86_400_000)).date,
    );
    const members = await sql<Member[]>`SELECT id, name FROM members ORDER BY id`;
    const rows = await sql<{ member_id: number; date: string; checked_in_at: Date }[]>`
      SELECT member_id, date::text AS date, checked_in_at FROM attendance
      WHERE date >= ${dates[dates.length - 1]}`;
    return c.json<HistoryResponse>({
      dates,
      members: members.map((m) => ({
        ...m,
        attended: Object.fromEntries(
          rows.filter((r) => r.member_id === m.id).map((r) => [r.date, r.checked_in_at.toISOString()]),
        ),
      })),
    });
  });

  app.onError((err, c) => {
    console.error(err);
    return c.json({ error: '서버 오류가 발생했어요.' }, 500);
  });

  return app;
}
