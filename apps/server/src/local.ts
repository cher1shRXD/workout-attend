// 로컬 개발용 Node 서버 (`pnpm dev`). 배포는 Vercel 이 src/index.ts 를 직접 쓴다.
import { serve } from '@hono/node-server';
import app from './index.js';

const port = Number(process.env.PORT) || 3000;
serve({ fetch: app.fetch, port, hostname: '0.0.0.0' }, (info) => {
  console.log(`server listening on http://localhost:${info.port}`);
});
