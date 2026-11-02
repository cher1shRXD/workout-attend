// 서버와 앱이 같이 쓰는 타입과 유틸.

/** 앨리스휘트니스 인천논현 (인천 남동구 논고개로123번길 17, 아이플렉스 509~511호) */
export const GYM = {
  name: '앨리스휘트니스 인천논현',
  latitude: 37.40163,
  longitude: 126.72276,
  /** 이 반경(m) 안이면 헬스장에 있는 걸로 본다. */
  radiusMeters: 100,
} as const;

export const TIME_ZONE = 'Asia/Seoul';

export type CheckinSource = 'manual' | 'geofence';

export interface Member {
  id: number;
  name: string;
}

export interface JoinRequest {
  name: string;
  code: string;
}

export interface JoinResponse {
  token: string;
  member: Member;
}

export interface CheckinRequest {
  latitude: number;
  longitude: number;
  /** 위치 정확도(m). 있으면 판정에 약간 반영한다. */
  accuracy?: number | null;
  source: CheckinSource;
}

export interface CheckinResponse {
  date: string;
  checkedInAt: string;
  alreadyCheckedIn: boolean;
  distanceMeters: number;
}

export interface TodayMember extends Member {
  /** ISO 시각. 안 왔으면 null */
  checkedInAt: string | null;
  /** 지금 운동 중이면 시작 시각 */
  activeSince: string | null;
}

export interface TodayResponse {
  date: string;
  /** @deprecated 예전 앱 호환용. 항상 0~24 (하루 종일 인정) */
  window: { startHour: number; endHour: number };
  gym: { name: string; latitude: number; longitude: number; radiusMeters: number };
  members: TodayMember[];
}

export interface HistoryResponse {
  dates: string[];
  members: (Member & { attended: Record<string, string> })[];
}

export type SessionSource = 'manual' | 'geofence';

export interface WorkoutSession {
  id: number;
  startedAt: string;
  /** 진행 중이면 null */
  endedAt: string | null;
}

export interface SessionResponse {
  session: WorkoutSession | null;
  /** start: 이미 운동 중이었음 / end: 진행 중인 운동이 없었음 */
  unchanged: boolean;
}

export interface CalendarEntry {
  memberId: number;
  attendedAt: string | null;
  /** 그날 운동한 총 시간(초). 진행 중인 운동은 지금까지 */
  seconds: number;
  sessions: { startedAt: string; endedAt: string | null }[];
}

export interface CalendarResponse {
  month: string;
  members: Member[];
  /** 날짜(YYYY-MM-DD, KST) → 기록 있는 멤버들 */
  days: Record<string, CalendarEntry[]>;
}

export interface ApiError {
  error: string;
}

/** 두 좌표 사이 거리(m), haversine. */
export function distanceMeters(
  a: { latitude: number; longitude: number },
  b: { latitude: number; longitude: number },
): number {
  const R = 6371000;
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(b.latitude - a.latitude);
  const dLng = toRad(b.longitude - a.longitude);
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(a.latitude)) * Math.cos(toRad(b.latitude)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

/** 한국 시간 기준 날짜(YYYY-MM-DD)와 시(0-23). */
export function kstParts(at: Date = new Date()): { date: string; hour: number } {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: TIME_ZONE,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(at);
  const get = (t: string) => parts.find((p) => p.type === t)!.value;
  return { date: `${get('year')}-${get('month')}-${get('day')}`, hour: Number(get('hour')) };
}
