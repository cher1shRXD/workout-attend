// 실제 Postgres가 필요하다: `docker compose up -d` 후
// TEST_DATABASE_URL=postgres://workout:workout@localhost:5432/workout pnpm test
import { after, before, beforeEach, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { GYM } from './shared.js';
import { createApp } from './routes.js';
import { loadConfig } from './config.js';
import { connect, migrate, type Sql } from './db.js';

const url = process.env.TEST_DATABASE_URL;

describe('api', { skip: !url && 'TEST_DATABASE_URL 미설정' }, () => {
  let sql: Sql;
  let clock = new Date('2026-11-02T22:30:00Z'); // KST 11-03 07:30
  let app: ReturnType<typeof createApp>;

  const call = async (method: string, path: string, body?: unknown, token?: string) => {
    const res = await app.request(path, {
      method,
      headers: {
        'content-type': 'application/json',
        ...(token ? { authorization: `Bearer ${token}` } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { status: res.status, json: (await res.json()) as any };
  };
  const join = async (name: string) => (await call('POST', '/api/join', { name, code: 'secret' })).json.token as string;
  const atGym = { latitude: GYM.latitude + 0.0003, longitude: GYM.longitude, source: 'manual' }; // ~33m

  before(async () => {
    sql = connect(url);
    await migrate(sql);
    app = createApp({
      sql,
      config: loadConfig({ GROUP_CODE: 'secret' }),
      now: () => clock,
    });
  });
  beforeEach(async () => {
    await sql`TRUNCATE members, attendance, sessions RESTART IDENTITY CASCADE`;
    clock = new Date('2026-11-02T22:30:00Z');
  });
  after(() => sql.end());

  it('가입 코드가 틀리면 거절', async () => {
    const r = await call('POST', '/api/join', { name: 'a', code: 'nope' });
    assert.equal(r.status, 403);
  });

  it('최대 3명, 같은 이름은 재로그인', async () => {
    const t1 = await join('태우');
    await join('민수');
    await join('지훈');
    assert.equal((await call('POST', '/api/join', { name: '넷째', code: 'secret' })).status, 403);
    const t1b = await join('태우');
    assert.notEqual(t1, t1b);
    assert.equal((await call('GET', '/api/me', undefined, t1)).status, 401);
    assert.equal((await call('GET', '/api/me', undefined, t1b)).json.name, '태우');
  });

  it('헬스장에서 아침에 출석, 하루 한 번만 기록', async () => {
    const a = await join('태우');
    const b = await join('민수');

    const r = await call('POST', '/api/checkin', atGym, a);
    assert.equal(r.status, 200);
    assert.equal(r.json.date, '2026-11-03');
    assert.equal(r.json.alreadyCheckedIn, false);

    const again = await call('POST', '/api/checkin', atGym, a);
    assert.equal(again.json.alreadyCheckedIn, true);

    const today = await call('GET', '/api/today', undefined, b);
    assert.equal(today.json.date, '2026-11-03');
    assert.ok(today.json.members.find((m: any) => m.name === '태우').checkedInAt);
    assert.equal(today.json.members.find((m: any) => m.name === '민수').checkedInAt, null);

    const hist = await call('GET', '/api/history?days=7', undefined, b);
    assert.equal(hist.json.dates.length, 7);
    assert.ok(hist.json.members[0].attended['2026-11-03']);
  });

  it('멀리 있으면 거절', async () => {
    const a = await join('태우');
    const r = await call('POST', '/api/checkin', { ...atGym, latitude: GYM.latitude + 0.01 }, a);
    assert.equal(r.status, 400);
    assert.match(r.json.error, /떨어져/);
  });

  it('아침 시간이 아니면 거절', async () => {
    const a = await join('태우');
    clock = new Date('2026-11-03T05:00:00Z'); // KST 14:00
    const r = await call('POST', '/api/checkin', atGym, a);
    assert.equal(r.status, 400);
    assert.match(r.json.error, /아침/);
  });

  it('토큰 없으면 401', async () => {
    assert.equal((await call('GET', '/api/today')).status, 401);
  });

  describe('운동 기록', () => {
    const at = (iso: string) => (clock = new Date(iso));

    it('수동 시작/종료, 중복 시작은 그대로', async () => {
      const a = await join('태우');
      at('2026-11-02T22:00:00Z'); // KST 11-03 07:00
      const s1 = await call('POST', '/api/sessions/start', { source: 'manual' }, a);
      assert.equal(s1.json.unchanged, false);
      at('2026-11-02T22:10:00Z');
      const s2 = await call('POST', '/api/sessions/start', { source: 'geofence' }, a);
      assert.equal(s2.json.unchanged, true);
      assert.equal(s2.json.session.id, s1.json.session.id);

      const today = await call('GET', '/api/today', undefined, a);
      assert.equal(today.json.members[0].activeSince, '2026-11-02T22:00:00.000Z');

      at('2026-11-02T23:30:00Z');
      const e = await call('POST', '/api/sessions/end', { source: 'manual' }, a);
      assert.equal(e.json.session.endedAt, '2026-11-02T23:30:00.000Z');
      assert.equal((await call('POST', '/api/sessions/end', {}, a)).json.unchanged, true);
      assert.equal((await call('GET', '/api/today', undefined, a)).json.members[0].activeSince, null);
    });

    it('달력: KST 날짜로 묶고 총 시간 합산, 진행 중은 지금까지', async () => {
      const a = await join('태우');
      const b = await join('민수');
      at('2026-11-02T22:00:00Z'); // KST 11-03 07:00
      await call('POST', '/api/checkin', atGym, a);
      await call('POST', '/api/sessions/start', {}, a);
      at('2026-11-02T23:00:00Z');
      await call('POST', '/api/sessions/end', {}, a);
      at('2026-11-03T10:00:00Z'); // KST 19:00
      await call('POST', '/api/sessions/start', {}, a);
      at('2026-11-03T10:30:00Z');
      await call('POST', '/api/sessions/start', {}, b);
      at('2026-11-03T11:00:00Z');

      const cal = await call('GET', '/api/calendar?month=2026-11', undefined, a);
      assert.equal(cal.json.month, '2026-11');
      const day = cal.json.days['2026-11-03'];
      const ta = day.find((x: any) => x.memberId === 1);
      const tb = day.find((x: any) => x.memberId === 2);
      assert.equal(ta.seconds, 3600 + 3600); // 1시간 + 진행 중 1시간
      assert.equal(ta.sessions.length, 2);
      assert.ok(ta.attendedAt);
      assert.equal(tb.seconds, 1800);
      assert.equal(tb.attendedAt, null);
      assert.deepEqual(Object.keys(cal.json.days), ['2026-11-03']);

      // month 없으면 이번 달(KST)
      assert.equal((await call('GET', '/api/calendar', undefined, a)).json.month, '2026-11');
      assert.deepEqual((await call('GET', '/api/calendar?month=2026-10', undefined, a)).json.days, {});
    });

    it('위치로 끝난 직후 다시 들어오면 이어붙이고, 수동 종료 후엔 새로 시작', async () => {
      const a = await join('태우');
      at('2026-11-02T22:00:00Z');
      const s1 = (await call('POST', '/api/sessions/start', { source: 'geofence' }, a)).json.session;
      at('2026-11-02T22:30:00Z');
      await call('POST', '/api/sessions/end', { source: 'geofence' }, a);
      at('2026-11-02T22:35:00Z');
      const s2 = (await call('POST', '/api/sessions/start', { source: 'geofence' }, a)).json.session;
      assert.equal(s2.id, s1.id);
      assert.equal(s2.endedAt, null);

      at('2026-11-02T23:00:00Z');
      await call('POST', '/api/sessions/end', { source: 'manual' }, a);
      at('2026-11-02T23:01:00Z');
      const s3 = (await call('POST', '/api/sessions/start', { source: 'manual' }, a)).json.session;
      assert.notEqual(s3.id, s1.id);
    });

    it('종료를 놓친 운동은 4시간으로 자동 종료', async () => {
      const a = await join('태우');
      at('2026-11-02T22:00:00Z');
      await call('POST', '/api/sessions/start', {}, a);
      at('2026-11-03T08:00:00Z');
      const today = await call('GET', '/api/today', undefined, a);
      assert.equal(today.json.members[0].activeSince, null);
      const cal = await call('GET', '/api/calendar?month=2026-11', undefined, a);
      assert.equal(cal.json.days['2026-11-03'][0].seconds, 4 * 3600);
    });
  });
});
