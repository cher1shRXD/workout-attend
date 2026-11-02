# 헬스 출첵 (workout-attend)

같은 헬스장에 다니는 친구 3명이 **오늘 헬스장에 갔는지** 서로 확인하는 아이폰 앱.
폰 위치가 **앨리스휘트니스 인천논현** (인천 남동구 논고개로123번길 17) 반경 100m 안이면 그날 출석으로 처리한다.

```
apps/
  server/   Node.js + Hono + PostgreSQL API  → Vercel + Neon 배포
  ios/      SwiftUI 아이폰 앱 (iOS 18+)
```

## 동작 방식

- **입실 = 출석 + 운동 시작, 퇴실 = 운동 종료.** 하루에 여러 번 들어갔다 나와도 모두 기록되고, 그날 첫 입실 시각이 출석 시각이다. 시간 제한 없이 하루 종일 인정되고, 날짜는 한국 시간 기준이다.
- **자동 기록**: 위치 권한을 **"항상" + "정확한 위치"**로 주면, 헬스장 반경에 들어가고 나올 때 iOS가 앱을 백그라운드로 깨워서 기록한다(`CLMonitor` 지오펜스). 앱이 꺼져 있어도 된다.
  - iOS 18부터는 `.always` `CLServiceSession` 을 들고 있어야 앱을 안 쓰는 동안 이벤트를 받는다. 앱이 실행될 때마다(백그라운드 실행 포함) 바로 세션을 다시 잡는다.
  - 깨어날 때 이벤트를 놓치는 경우가 있어서, 백그라운드 실행 시와 앱을 열 때 현재 위치를 마지막 처리 상태(안/밖)와 비교해 놓친 입실·퇴실을 보정한다. 헬스장 안에서 직접 운동을 끝낸 뒤 앱을 다시 열어도 다시 시작되지는 않는다.
  - 사용자가 앱 전환기에서 앱을 위로 쓸어 강제 종료하면 iOS 정책상 다시 깨워주지 않을 수 있다.
  - 위치가 잠깐 튀어서 나갔다가 10분 안에 다시 들어오면 같은 운동으로 이어붙인다.
  - 퇴실을 놓친 운동은 4시간 뒤 자동 종료된다(`MAX_SESSION_HOURS`).
- **수동 기록(보조 수단)**: 화면 맨 위 버튼. 수동 운동 시작은 출석이기도 해서 헬스장 반경 안(GPS 오차 최대 50m 허용)에서만 된다. 운동 종료는 어디서든 된다.
- **달력**: 이번 달부터 보여주고, 날짜를 누르면 그날 누가 몇 시간 운동했는지, 언제 들어오고 나갔는지 바텀시트로 보여준다.
- **알림**: 입실·퇴실 때 내 폰에 로컬 알림이 뜬다. 친구들 현황은 앱을 열어서 확인한다(서버 푸시 없음).
- **가입**: 이름과 공유 가입 코드(`GROUP_CODE`)로 가입하고 최대 3명까지. 폰을 바꾸면 같은 이름으로 다시 가입하면 된다.

## 로컬 개발

```bash
pnpm install
docker compose up -d                        # 로컬 Postgres
cp apps/server/.env.example apps/server/.env  # GROUP_CODE 수정
pnpm dev                                    # http://localhost:3000

# 테스트 (Postgres 필요)
TEST_DATABASE_URL=postgres://workout:workout@localhost:5432/workout pnpm test
```

iOS:

```bash
brew install xcodegen
cd apps/ios && xcodegen generate   # project.yml 을 고치면 다시 실행
open WorkoutAttend.xcodeproj
```

- Debug 빌드는 `http://localhost:3000` 을, Release 빌드는 `project.yml` 의 `API_BASE_URL` 을 쓴다. **Vercel 주소로 바꿔야 한다.**
- 실기기에서 로컬 서버를 쓰려면 Debug `API_BASE_URL` 을 `http://<맥 IP>:3000` 으로 바꾼다.
- 시뮬레이터에서 위치 테스트: `xcrun simctl location booted set 37.40163,126.72276`

## Vercel + Neon 배포 (서버, 무료)

Vercel 무료(Hobby) 플랜은 서버를 요청이 올 때만 실행하고, 잠들어 있다가도 1초 안에 깨어난다. 그래서 백그라운드 지오펜스로 출석할 때도(앱에 주어지는 시간이 약 30초) 안전하다.

1. GitHub에 이 저장소를 올린다.
2. [vercel.com](https://vercel.com) → **Add New Project** → 저장소 선택
   - **Root Directory: `apps/server`** (Framework는 Hono로 자동 인식된다)
3. 프로젝트 → **Storage** → **Neon** (Marketplace) → Free 플랜으로 DB 생성 → 프로젝트에 연결
   - 리전은 **Singapore (ap-southeast-1)** 로 고른다. `vercel.json` 에서 함수 리전을 `sin1` 으로 맞춰 뒀다.
   - `DATABASE_URL` 이 자동으로 들어간다. 테이블은 첫 요청 때 자동으로 만든다.
4. **Settings → Environment Variables** 에 아래 값을 넣고 Redeploy 한다.
5. `https://<프로젝트>.vercel.app/api/health` 가 `{"ok":true}` 를 주면 끝이다. 이 주소를 `apps/ios/project.yml` 의 Release `API_BASE_URL` 에 넣는다. (현재 배포: https://workout-attend.vercel.app)

이후에는 main 브랜치에 push 하면 자동으로 다시 배포된다.

환경변수:

| 이름 | 필수 | 설명 |
|---|---|---|
| `GROUP_CODE` | ✅ | 친구들끼리만 아는 가입 코드 |
| `MAX_MEMBERS` | | 기본 3 |
| `MAX_SESSION_HOURS` | | 종료를 놓친 운동 자동 종료 시간, 기본 4 |
| `GYM_LATITUDE` / `GYM_LONGITUDE` / `GYM_RADIUS_METERS` | | 헬스장 좌표 덮어쓰기 |

## 친구 폰에 설치하기

- **유료 Apple Developer Program (연 $99)**: Archive → **TestFlight** 로 올리고 친구 2명을 테스터로 초대한다. 가장 편하다.
- **무료 Apple ID**: 각자 맥과 Xcode에서 자기 Apple ID를 Team으로 골라 폰에 직접 설치한다. 7일마다 다시 설치해야 한다.

공통:
1. Xcode > Signing & Capabilities 에서 Team을 선택한다. 번들 ID가 이미 쓰이고 있으면 `project.yml` 에서 바꾸고 `xcodegen generate` 한다.
2. 각자 앱에서 이름과 가입 코드를 넣고, 위치 권한은 **"항상 허용"**, 알림은 허용한다.

## 헬스장 좌표

`apps/server/src/shared.ts` 의 `GYM` 과 `apps/ios/WorkoutAttend/Services/Config.swift` 의 `Gym` 을 같은 값으로 맞춘다.
현재 값(37.40163, 126.72276)은 OpenStreetMap에서 같은 건물(논고개로123번길 17)을 찾아 얻은 좌표다. 실제로 헬스장 안에서 한 번 출석해 보고 거리가 이상하면 조정한다.
