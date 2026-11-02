import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { Hono } from 'hono';
import { cors } from 'hono/cors';
import {
  distanceMeters,
  kstParts,
  type CheckinRequest,
  type CheckinResponse,
  type HistoryResponse,
  type JoinResponse,
  type Member,
  type TodayResponse,
} from './shared.js';
import type { Config } from './config.js';
import type { Sql } from './db.js';
import type { PushEnv, PushSender } from './push.js';

/** 위치 정확도가 나쁠 때 반경에 더해주는 최대 여유(m). */
const MAX_ACCURACY_SLACK = 50;

const hashToken = (t: string) => createHash('sha256').update(t).digest('hex');

const safeEqual = (a: string, b: string) => {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
};

const isCoord = (v: unknown, max: number) =>
  typeof v === 'number' && Number.isFinite(v) && Math.abs(v) <= max;

export interface Deps {
  sql: Sql;
  config: Config;
  push: PushSender;
  now?: () => Date;
  /** 첫 요청 전에 한 번 실행 (테이블 생성 등) */
  init?: () => Promise<void>;
}

type Env = { Variables: { member: Member } };

export function createApp({ sql, config, push, now = () => new Date(), init }: Deps) {
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

  app.put('/api/push-token', async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const token = typeof body.token === 'string' && /^[0-9a-f]{32,200}$/i.test(body.token) ? body.token : null;
    const env = body.environment === 'sandbox' ? 'sandbox' : 'production';
    await sql`UPDATE members SET push_token = ${token}, push_env = ${env} WHERE id = ${c.get('member').id}`;
    return c.json({ ok: true });
  });

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
      const others = await sql<{ push_token: string; push_env: PushEnv }[]>`
        SELECT push_token, push_env FROM members WHERE id <> ${me.id} AND push_token IS NOT NULL`;
      const time = at.toLocaleTimeString('ko-KR', { timeZone: 'Asia/Seoul', hour: '2-digit', minute: '2-digit' });
      // 서버리스에서는 응답 후 작업이 끊길 수 있어서 보내고 나서 응답한다
      await push(others.map((o) => ({ token: o.push_token, env: o.push_env })), '💪 출석!', `${me.name}님이 ${time}에 헬스장 도착했어요.`);
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

  app.get('/api/today', async (c) => {
    const { date } = kstParts(now());
    const rows = await sql<{ id: number; name: string; checked_in_at: Date | null }[]>`
      SELECT m.id, m.name, a.checked_in_at
      FROM members m
      LEFT JOIN attendance a ON a.member_id = m.id AND a.date = ${date}
      ORDER BY m.id`;
    return c.json<TodayResponse>({
      date,
      window: { startHour: config.morningStartHour, endHour: config.morningEndHour },
      gym: config.gym,
      members: rows.map((r) => ({
        id: r.id,
        name: r.name,
        checkedInAt: r.checked_in_at ? r.checked_in_at.toISOString() : null,
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
