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
  const pushes: { targets: { token: string; env: string }[]; body: string }[] = [];
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
      push: async (targets, _t, body) => void pushes.push({ targets, body }),
      now: () => clock,
    });
  });
  beforeEach(async () => {
    await sql`TRUNCATE members, attendance RESTART IDENTITY CASCADE`;
    pushes.length = 0;
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

  it('헬스장에서 아침에 출석, 친구에게 푸시', async () => {
    const a = await join('태우');
    const b = await join('민수');
    await call('PUT', '/api/push-token', { token: 'ab'.repeat(32), environment: 'sandbox' }, b);

    const r = await call('POST', '/api/checkin', atGym, a);
    assert.equal(r.status, 200);
    assert.equal(r.json.date, '2026-11-03');
    assert.equal(r.json.alreadyCheckedIn, false);
    assert.deepEqual(pushes[0].targets, [{ token: 'ab'.repeat(32), env: 'sandbox' }]);

    const again = await call('POST', '/api/checkin', atGym, a);
    assert.equal(again.json.alreadyCheckedIn, true);
    assert.equal(pushes.length, 1);

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
});
