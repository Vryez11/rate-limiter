# rate-limiter

HTTP API 앞에서 클라이언트별 요청 수를 제한하는 처리율 제한 장치다. 한도를 넘은 요청에는 429와 `Retry-After`를 돌려준다.

『가상 면접 사례로 배우는 대규모 시스템 설계 기초』 4장의 알고리즘들을 직접 구현하면서, 각 구현 아래에서 실제로 무슨 일이 일어나는지를 실험으로 확인하고 기록하는 학습 프로젝트다. 마일스톤마다 "예측 → 실험 → 코드에서 운영체제까지 내려가며 원인 추적" 순서로 진행하고, 그 과정을 `docs/`에 남긴다.

## 진행 상태

| | 마일스톤 | 내용 | 기록 |
|---|---|---|---|
| 진행 중 | M1. 고정 윈도 + 필터 | 서블릿 필터, 고정 윈도 카운터, 429 응답과 헤더 | [docs/01-fixed-window-filter.md](docs/01-fixed-window-filter.md) |
| 예정 | M2. 동시 요청 실험과 동기화 | 코어를 동시에 호출하는 실험 하네스, 동기화 방식별 구현 비교 | |
| 예정 | M3. 토큰 버킷 | 설정으로 알고리즘 교체, 버스트와 리필 | |
| 예정 | M4. 슬라이딩 윈도 2종 + 키 만료 | 로그 방식, 카운터 방식, 안 쓰는 키 정리 | |
| 예정 | M5. Redis 분산 제한 | 서버 여러 대가 한도 하나를 공유 | |

M1은 코드와 실험 스크립트까지 끝났고 실험과 딥다이브 기록이 남아 있다. 현재 구현은 단일 스레드 기준의 가장 단순한 형태이며, 동시 요청에 대한 처리는 M2에서 다룬다.

## 동작 방식

```
client --HTTP--> Tomcat worker thread
                     |
                 RateLimitFilter                         web/  (Spring 어댑터)
                     |  key = X-Api-Key 또는 IP
                     v
                 RateLimiter.tryAcquire(key) --> Decision(allowed, remaining, resetAfter)
                     |                                   core/ (순수 Java)
                 FixedWindowRateLimiter
                     |
                 Map<key, Window(start, count)>

  allowed -> chain.doFilter -> PingController -> 200
  denied  -> 429 + Retry-After
```

알고리즘 코어(`core` 패키지)는 Spring에 의존하지 않는다. Spring Boot 쪽은 코어의 판정을 HTTP 응답으로 옮기는 필터 하나다. 코어만 떼어서 스레드로 직접 호출하는 실험을 하기 위한 구조다.

## 실행

요구 사항: JDK 21. Gradle은 래퍼가 받아 온다.

```bash
export JAVA_HOME=$(/usr/libexec/java_home -v 21)   # macOS에서 기본 JDK가 21이 아닐 때
./gradlew build
java -jar build/libs/rate-limiter-0.0.1-SNAPSHOT.jar
```

기본 설정은 10초에 5개다. 같은 키로 7번 요청하면 여섯 번째부터 거부된다.

```bash
for i in 1 2 3 4 5 6 7; do
  curl -s -o /dev/null -D - -H 'X-Api-Key: demo' localhost:8080/api/ping \
    | grep -E '^(HTTP|X-RateLimit-Remaining|Retry-After)'
done
```

```
HTTP/1.1 200
X-RateLimit-Remaining: 4
...
HTTP/1.1 200
X-RateLimit-Remaining: 0
HTTP/1.1 429
X-RateLimit-Remaining: 0
Retry-After: 10
```

## 응답 규격

| 헤더 | 붙는 응답 | 뜻 |
|---|---|---|
| `X-RateLimit-Limit` | 모든 `/api/*` 응답 | 윈도 하나에 허용하는 요청 수 |
| `X-RateLimit-Remaining` | 모든 `/api/*` 응답 | 현재 윈도에서 남은 요청 수 |
| `X-RateLimit-Reset` | 모든 `/api/*` 응답 | 한도가 다시 채워질 때까지 남은 초(올림) |
| `Retry-After` | 429 응답 | 다시 시도하기까지 기다릴 초(올림) |

거부된 요청의 본문:

```json
{"error":"too_many_requests","retryAfterSeconds":10}
```

클라이언트는 `X-Api-Key` 헤더로 구분하고, 헤더가 없으면 접속 IP로 구분한다.

## 설정

`src/main/resources/application.yml` 또는 실행 인자(`--ratelimit.limit=100`)로 바꾼다.

| 키 | 기본값 | 설명 |
|---|---|---|
| `ratelimit.enabled` | `true` | `false`면 필터를 등록하지 않는다 |
| `ratelimit.limit` | `5` | 윈도 하나에 허용하는 요청 수 |
| `ratelimit.window` | `10s` | 윈도 크기 (`500ms`, `1m` 같은 Duration 표기) |
| `ratelimit.alignment` | `epoch` | 윈도의 시작을 시계에 맞출지(`epoch`), 키의 첫 요청에 맞출지(`first-request`) |
| `logging.level.com.vryez.ratelimiter` | `INFO` | `DEBUG`면 필터가 요청마다 키, 판정, 클라이언트 포트, 스레드 이름을 남긴다 |

## 프로젝트 구조

```
├── src/main/java/com/vryez/ratelimiter/
│   ├── core/          RateLimiter, Decision, FixedWindowRateLimiter (Spring 의존 없음)
│   ├── web/           RateLimitFilter, RateLimitConfig, RateLimitProperties, PingController
│   └── RateLimiterApplication.java
├── src/test/java/...  코어 단위 테스트(시간을 손으로 움직이는 MutableClock), MockMvc 필터 테스트
├── docs/              설계와 마일스톤별 기록
└── experiments/       다시 실행할 수 있는 실험 스크립트
    └── results/       실험 출력 원문
```

## 실험

`experiments/`의 스크립트는 서버를 별도 포트(18080번대)에 직접 띄우고, 관측한 뒤 정리한다. `--check`를 붙이면 결과 값은 내지 않고 스크립트의 배선만 점검한다.

| 스크립트 | 보는 것 |
|---|---|
| `experiments/m1-worker-threads.sh` | 요청 전후의 스레드 덤프, 새 연결과 keep-alive 연결에서 필터를 실행한 스레드 |
| `experiments/m1-window-boundary.sh` | 윈도가 끝나는 시점 앞뒤로 요청 묶음을 보냈을 때의 판정. `--align`, `--schedule`로 조건을 바꾼다 |

출력 원문은 `experiments/results/<실험 이름>.<날짜>.txt`에 남기고, `docs/`의 기록이 이 파일들을 근거로 가리킨다.

## 문서

- [docs/00-design.md](docs/00-design.md): 범위, 스택 선택, 구조, 마일스톤, 진행 메모
- [docs/01-fixed-window-filter.md](docs/01-fixed-window-filter.md): M1에서 만든 것, 코드 읽는 순서, 핵심 결정과 저울질한 대안

마일스톤 기록에서는 근거를 세 가지로 구분해 적는다. "관측"은 직접 돌려서 본 것, "문서"는 공식 문서나 소스를 열어 확인한 것, "추정"은 확인하지 못한 것이다.

## 기술 스택

Java 21, Spring Boot 4.1.0 (Spring MVC, 내장 Tomcat), Gradle 9.5.1, JUnit 5, AssertJ. 실험 스크립트는 bash, curl, perl, jcmd를 쓴다.
