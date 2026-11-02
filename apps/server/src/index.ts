// Vercel 진입점: Vercel 이 src/index.ts 의 default export(Hono 앱)를 함수로 실행한다.
import { Hono } from 'hono';
import { loadConfig } from './config.js';
import { connect, migrate } from './db.js';
import { apnsConfigFromEnv, createApnsSender } from './push.js';
import { createApp } from './routes.js';

const sql = connect();

const app = new Hono();
app.route(
  '/',
  createApp({
    sql,
    config: loadConfig(),
    push: createApnsSender(apnsConfigFromEnv()),
    init: () => migrate(sql),
  }),
);

export default app;
