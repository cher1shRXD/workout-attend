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
  const at = (iso: string) => (clock = new Date(iso));
  const start = (token: string, body: object = atGym) => call('POST', '/api/sessions/start', body, token);
  const end = (token: string, source = 'manual') => call('POST', '/api/sessions/end', { source }, token);

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

  it('토큰 없으면 401', async () => {
    assert.equal((await call('GET', '/api/today')).status, 401);
  });

  describe('입실(출석·운동 시작) / 퇴실(운동 종료)', () => {
    it('수동 입실은 헬스장 반경 안에서만, 위치 없으면 거절', async () => {
      const a = await join('태우');
      const far = await start(a, { ...atGym, latitude: GYM.latitude + 0.01 });
      assert.equal(far.status, 400);
      assert.match(far.json.error, /떨어져/);
      assert.equal((await start(a, { source: 'manual' })).status, 400);
      assert.equal((await start(a)).status, 200);
    });

    it('지오펜스 입실은 좌표 없이 가능', async () => {
      const a = await join('태우');
      const r = await start(a, { source: 'geofence' });
      assert.equal(r.status, 200);
      assert.equal(r.json.unchanged, false);
    });

    it('입실하면 출석, 퇴실은 위치 없이 가능, 중복 입실은 그대로', async () => {
      const a = await join('태우');
      const b = await join('민수');
      at('2026-11-02T22:00:00Z'); // KST 11-03 07:00
      const s1 = await start(a);
      at('2026-11-02T22:10:00Z');
      const s2 = await start(a, { source: 'geofence' });
      assert.equal(s2.json.unchanged, true);
      assert.equal(s2.json.session.id, s1.json.session.id);

      let today = await call('GET', '/api/today', undefined, b);
      assert.equal(today.json.date, '2026-11-03');
      const ta = today.json.members.find((m: any) => m.name === '태우');
      assert.equal(ta.checkedInAt, '2026-11-02T22:00:00.000Z');
      assert.equal(ta.activeSince, '2026-11-02T22:00:00.000Z');
      assert.equal(ta.seconds, 600);
      assert.equal(today.json.members.find((m: any) => m.name === '민수').checkedInAt, null);

      at('2026-11-02T23:30:00Z');
      const e = await end(a);
      assert.equal(e.json.session.endedAt, '2026-11-02T23:30:00.000Z');
      assert.equal((await end(a)).json.unchanged, true);
      today = await call('GET', '/api/today', undefined, a);
      assert.equal(today.json.members[0].activeSince, null);
      assert.equal(today.json.members[0].seconds, 5400);
    });

    it('하루에 여러 번: 출석은 첫 입실, 시간은 합산, 밤에도 인정', async () => {
      const a = await join('태우');
      const b = await join('민수');
      at('2026-11-02T22:00:00Z'); // KST 11-03 07:00
      await start(a);
      at('2026-11-02T23:00:00Z');
      await end(a);
      at('2026-11-03T13:00:00Z'); // KST 22:00
      await start(a);
      at('2026-11-03T13:30:00Z');
      await start(b, { source: 'geofence' });
      at('2026-11-03T14:00:00Z'); // KST 23:00

      const today = await call('GET', '/api/today', undefined, a);
      const ta = today.json.members[0];
      assert.equal(ta.visits, 2);
      assert.equal(ta.seconds, 3600 + 3600);
      assert.equal(ta.checkedInAt, '2026-11-02T22:00:00.000Z');

      const cal = await call('GET', '/api/calendar?month=2026-11', undefined, a);
      assert.equal(cal.json.month, '2026-11');
      const day = cal.json.days['2026-11-03'];
      assert.equal(day.find((x: any) => x.memberId === 1).sessions.length, 2);
      assert.equal(day.find((x: any) => x.memberId === 1).attendedAt, '2026-11-02T22:00:00.000Z');
      assert.equal(day.find((x: any) => x.memberId === 2).seconds, 1800);
      assert.deepEqual(Object.keys(cal.json.days), ['2026-11-03']);
      assert.equal((await call('GET', '/api/calendar', undefined, a)).json.month, '2026-11');
      assert.deepEqual((await call('GET', '/api/calendar?month=2026-10', undefined, a)).json.days, {});
    });

    it('자정 넘겨 운동 중이면 오늘 현황에도 운동 중으로 보임', async () => {
      const a = await join('태우');
      at('2026-11-03T14:30:00Z'); // KST 23:30
      await start(a);
      at('2026-11-03T15:30:00Z'); // KST 다음날 00:30
      const today = await call('GET', '/api/today', undefined, a);
      assert.equal(today.json.date, '2026-11-04');
      assert.equal(today.json.members[0].activeSince, '2026-11-03T14:30:00.000Z');
      assert.equal(today.json.members[0].checkedInAt, null);
    });

    it('위치로 퇴실 직후 다시 들어오면 이어붙이고, 수동 퇴실 후엔 새로 입실', async () => {
      const a = await join('태우');
      at('2026-11-02T22:00:00Z');
      const s1 = (await start(a, { source: 'geofence' })).json.session;
      at('2026-11-02T22:30:00Z');
      await end(a, 'geofence');
      at('2026-11-02T22:35:00Z');
      const s2 = (await start(a, { source: 'geofence' })).json.session;
      assert.equal(s2.id, s1.id);
      assert.equal(s2.endedAt, null);

      at('2026-11-02T23:00:00Z');
      await end(a, 'manual');
      at('2026-11-02T23:01:00Z');
      const s3 = (await start(a)).json.session;
      assert.notEqual(s3.id, s1.id);
    });

    it('퇴실을 놓친 운동은 4시간으로 자동 종료', async () => {
      const a = await join('태우');
      at('2026-11-02T22:00:00Z');
      await start(a);
      at('2026-11-03T08:00:00Z');
      const today = await call('GET', '/api/today', undefined, a);
      assert.equal(today.json.members[0].activeSince, null);
      assert.equal(today.json.members[0].seconds, 4 * 3600);
    });

    it('예전 앱의 출석 체크 API는 위치 확인 후 입실로 처리', async () => {
      const a = await join('태우');
      const r = await call('POST', '/api/checkin', atGym, a);
      assert.equal(r.status, 200);
      assert.equal(r.json.alreadyCheckedIn, false);
      assert.equal((await call('POST', '/api/checkin', atGym, a)).json.alreadyCheckedIn, true);
      assert.ok((await call('GET', '/api/today', undefined, a)).json.members[0].activeSince);
      assert.equal((await call('POST', '/api/checkin', { ...atGym, latitude: GYM.latitude + 0.01 }, a)).status, 400);
    });
  });
});
