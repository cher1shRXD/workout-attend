// APNs(애플 푸시)로 알림을 보낸다. 설정이 없으면 아무것도 안 함. 실패해도 출석 처리에는 영향 없음.
import { createPrivateKey, sign, type KeyObject } from 'node:crypto';
import http2 from 'node:http2';

export type PushEnv = 'sandbox' | 'production';
export interface PushTarget {
  token: string;
  env: PushEnv;
}
export type PushSender = (targets: PushTarget[], title: string, body: string) => Promise<void>;

export interface ApnsConfig {
  /** .p8 키 파일 내용 (줄바꿈은 실제 줄바꿈 또는 \n 문자열 모두 허용) */
  key: string;
  keyId: string;
  teamId: string;
  bundleId: string;
}

export function apnsConfigFromEnv(env: NodeJS.ProcessEnv = process.env): ApnsConfig | null {
  const { APNS_KEY, APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID } = env;
  if (!APNS_KEY || !APNS_KEY_ID || !APNS_TEAM_ID || !APNS_BUNDLE_ID) return null;
  return {
    key: APNS_KEY.replace(/\\n/g, '\n'),
    keyId: APNS_KEY_ID,
    teamId: APNS_TEAM_ID,
    bundleId: APNS_BUNDLE_ID,
  };
}

const HOSTS: Record<PushEnv, string> = {
  production: 'https://api.push.apple.com',
  sandbox: 'https://api.sandbox.push.apple.com',
};

const b64url = (v: string | Buffer) => Buffer.from(v).toString('base64url');

export function createApnsSender(cfg: ApnsConfig | null): PushSender {
  if (!cfg) {
    console.warn('APNS_* 환경변수가 없어 푸시 알림을 보내지 않습니다.');
    return async () => {};
  }
  const key: KeyObject = createPrivateKey(cfg.key);
  let jwt = { value: '', issuedAt: 0 };

  // APNs 토큰은 20분~1시간 사이에 재발급해야 한다.
  const authToken = () => {
    const now = Math.floor(Date.now() / 1000);
    if (now - jwt.issuedAt > 40 * 60) {
      const header = b64url(JSON.stringify({ alg: 'ES256', kid: cfg.keyId }));
      const claims = b64url(JSON.stringify({ iss: cfg.teamId, iat: now }));
      const sig = sign('sha256', Buffer.from(`${header}.${claims}`), { key, dsaEncoding: 'ieee-p1363' });
      jwt = { value: `${header}.${claims}.${b64url(sig)}`, issuedAt: now };
    }
    return jwt.value;
  };

  const sendOne = (client: http2.ClientHttp2Session, token: string, payload: string) =>
    new Promise<void>((resolve) => {
      const req = client.request({
        ':method': 'POST',
        ':path': `/3/device/${token}`,
        authorization: `bearer ${authToken()}`,
        'apns-topic': cfg.bundleId,
        'apns-push-type': 'alert',
        'apns-priority': '10',
        'content-type': 'application/json',
      });
      let status = 0;
      let data = '';
      req.on('response', (h) => (status = Number(h[':status'])));
      req.on('data', (c) => (data += c));
      req.on('end', () => {
        if (status !== 200) console.error('APNs 실패', status, data);
        resolve();
      });
      req.on('error', (e) => {
        console.error('APNs 실패', e);
        resolve();
      });
      req.end(payload);
    });

  return async (targets, title, body) => {
    if (targets.length === 0) return;
    const payload = JSON.stringify({ aps: { alert: { title, body }, sound: 'default' } });
    for (const env of ['sandbox', 'production'] as const) {
      const tokens = targets.filter((t) => t.env === env).map((t) => t.token);
      if (tokens.length === 0) continue;
      const client = http2.connect(HOSTS[env]);
      client.on('error', (e) => console.error('APNs 연결 실패', e));
      try {
        await Promise.all(tokens.map((t) => sendOne(client, t, payload)));
      } finally {
        client.close();
      }
    }
  };
}
