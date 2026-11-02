import { GYM } from './shared.js';

const num = (v: string | undefined, fallback: number) => {
  const n = Number(v);
  return v !== undefined && v !== '' && Number.isFinite(n) ? n : fallback;
};

export interface Config {
  port: number;
  groupCode: string;
  maxMembers: number;
  morningStartHour: number;
  morningEndHour: number;
  /** 종료를 놓친 운동은 이 시간 뒤 자동 종료 */
  maxSessionHours: number;
  gym: { name: string; latitude: number; longitude: number; radiusMeters: number };
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const groupCode = env.GROUP_CODE?.trim();
  if (!groupCode) throw new Error('GROUP_CODE 환경변수가 필요합니다.');
  return {
    port: num(env.PORT, 3000),
    groupCode,
    maxMembers: num(env.MAX_MEMBERS, 3),
    morningStartHour: num(env.MORNING_START_HOUR, 4),
    morningEndHour: num(env.MORNING_END_HOUR, 12),
    maxSessionHours: num(env.MAX_SESSION_HOURS, 4),
    gym: {
      name: GYM.name,
      latitude: num(env.GYM_LATITUDE, GYM.latitude),
      longitude: num(env.GYM_LONGITUDE, GYM.longitude),
      radiusMeters: num(env.GYM_RADIUS_METERS, GYM.radiusMeters),
    },
  };
}
