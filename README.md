# 헬스 출첵 (workout-attend)

같은 헬스장에 다니는 친구 3명이 **아침에 헬스장에 갔는지** 서로 확인하는 아이폰 앱.
폰 위치가 **앨리스휘트니스 인천논현** (인천 남동구 논고개로123번길 17) 반경 100m 안이면 그날 출석으로 처리한다.

```
apps/
  server/   Node.js + Hono + PostgreSQL API  → Vercel + Neon 배포
  ios/      SwiftUI 아이폰 앱 (iOS 18+)
```

## 동작 방식

- **자동 출석**: 위치 권한을 "항상"으로 주면, 헬스장 반경에 들어갈 때 iOS가 앱을 백그라운드로 깨워서 출석시킨다(`CLMonitor` 지오펜스). 앱을 열지 않아도 된다.
- **앱 열 때 자동 출석**: 앱을 열었는데 헬스장이면 조용히 출석 처리.
- **수동 출석**: "지금 출석 체크" 버튼.
- **친구 알림**: 누가 출석하면 나머지 친구들에게 푸시(APNs)가 간다.
- **판정은 서버가 한다**: 한국 시간 **4시~12시** 사이에 보낸 좌표가 헬스장 반경 안이어야 인정(GPS 오차 최대 50m까지 봐줌). 하루 1번만 기록된다.
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
5. `https://<프로젝트>.vercel.app/api/health` 가 `{"ok":true}` 를 주면 끝이다. 이 주소를 `apps/ios/project.yml` 의 Release `API_BASE_URL` 에 넣는다.

이후에는 main 브랜치에 push 하면 자동으로 다시 배포된다.

환경변수:

| 이름 | 필수 | 설명 |
|---|---|---|
| `GROUP_CODE` | ✅ | 친구들끼리만 아는 가입 코드 |
| `APNS_KEY` | 푸시용 | Apple `.p8` 키 내용 (줄바꿈은 `\n` 으로 써도 됨) |
| `APNS_KEY_ID` | 푸시용 | 키 ID |
| `APNS_TEAM_ID` | 푸시용 | Apple Developer Team ID |
| `APNS_BUNDLE_ID` | 푸시용 | 앱 번들 ID (`dev.workoutattend.app`, 바꿨다면 그 값) |
| `MAX_MEMBERS` | | 기본 3 |
| `MORNING_START_HOUR` / `MORNING_END_HOUR` | | 기본 4 / 12 (KST) |
| `GYM_LATITUDE` / `GYM_LONGITUDE` / `GYM_RADIUS_METERS` | | 헬스장 좌표 덮어쓰기 |

APNS_* 가 없으면 푸시만 안 가고 나머지는 정상 동작한다.

## 친구 폰에 설치하기

1. Apple Developer Program(유료) 계정으로 Xcode > Signing & Capabilities 에서 Team을 선택한다. 번들 ID가 이미 쓰이고 있으면 `project.yml` 에서 바꾼다.
2. developer.apple.com 에서 APNs 키(.p8)를 발급해 위 환경변수로 넣는다.
3. Archive → **TestFlight** 로 올리고 친구 2명을 테스터로 초대한다.
   - Release/TestFlight 빌드는 `aps-environment` 가 production 으로 서명되고, 앱이 그에 맞춰 서버에 토큰 환경을 알려준다.
4. 각자 앱에서 이름과 가입 코드를 넣고, 위치 권한은 **"항상 허용"**, 알림은 허용한다.

## 헬스장 좌표

`apps/server/src/shared.ts` 의 `GYM` 과 `apps/ios/WorkoutAttend/Services/Config.swift` 의 `Gym` 을 같은 값으로 맞춘다.
현재 값(37.40163, 126.72276)은 OpenStreetMap에서 같은 건물(논고개로123번길 17)을 찾아 얻은 좌표다. 실제로 헬스장 안에서 한 번 출석해 보고 거리가 이상하면 조정한다.
