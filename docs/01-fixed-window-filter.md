# M1. 고정 윈도 + 필터

## 만든 것

`/api/*` 요청을 서블릿 필터가 가로채서 키별로 요청 수를 센다. 윈도 하나(기본 10초)에 한도(기본 5개)까지는 통과시키고, 넘으면 429와 `Retry-After`를 돌려준다. 모든 응답에 `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset` 헤더가 붙는다. 알고리즘은 고정 윈도 카운터이고, 상태 관리는 가장 단순한 형태(`HashMap`, 동기화 없음)로 두었다.

실행:

```bash
cd ~/Vryez11/rate-limiter
export JAVA_HOME=$(/usr/libexec/java_home -v 21)
./gradlew build                      # 테스트 9개 포함
java -jar build/libs/rate-limiter-0.0.1-SNAPSHOT.jar
# 다른 터미널에서
for i in 1 2 3 4 5 6 7; do curl -s -o /dev/null -D - -H 'X-Api-Key: demo' localhost:8080/api/ping | grep -E '^(HTTP|X-RateLimit-Remaining|Retry-After)'; done
```

확인한 출력(2026-09-20, 요청마다 세 줄로 나오는 것을 한 줄로 붙였다):

```
HTTP/1.1 200  X-RateLimit-Remaining: 4
HTTP/1.1 200  X-RateLimit-Remaining: 3
HTTP/1.1 200  X-RateLimit-Remaining: 2
HTTP/1.1 200  X-RateLimit-Remaining: 1
HTTP/1.1 200  X-RateLimit-Remaining: 0
HTTP/1.1 429  X-RateLimit-Remaining: 0 Retry-After: 10
HTTP/1.1 429  X-RateLimit-Remaining: 0 Retry-After: 10
```

429의 본문은 `{"error":"too_many_requests","retryAfterSeconds":10}`이다. 키를 `other`로 바꾸면 남은 수가 4부터 다시 시작한다. `X-Api-Key` 없이 보내면 IP가 키가 된다.

## 코드 읽는 순서

1. `web/RateLimitConfig.java:29-37` 필터를 `/api/*`에, 다른 필터보다 앞 순서로 등록한다
2. `web/RateLimitFilter.java:32-53` doFilterInternal(): 키 추출, 코어 호출, 헤더 기록, 통과 또는 429
3. `web/RateLimitFilter.java:55-61` resolveKey(): `X-Api-Key`가 있으면 그것, 없으면 접속 IP
4. `core/RateLimiter.java`, `core/Decision.java` 코어의 인터페이스와 판정 결과. `Decision.java:16-18`이 밀리초를 초로 올림한다
5. `core/FixedWindowRateLimiter.java:32-45` tryAcquire(): 현재 윈도를 찾거나 새로 열고, 한도와 비교한 뒤 센다
6. `core/FixedWindowRateLimiter.java:47-52` windowStart(): 윈도의 시작 시각을 정하는 두 가지 방식
7. `web/RateLimitProperties.java`, `resources/application.yml` 설정으로 바꿀 수 있는 값
8. `test/.../core/FixedWindowRateLimiterTest.java` `MutableClock`으로 시간을 움직이며 확인하는 단위 테스트

메인 코드는 모두 합쳐 241줄이다.

## 핵심 결정

### 결정 1. 제한을 어디에 끼우는가 (`web/RateLimitConfig.java:29-37`)

| 방식 | 동작 | 얻는 것 | 치르는 것 |
|---|---|---|---|
| A. 서블릿 필터 (선택) | DispatcherServlet보다 앞, 서블릿 컨테이너의 필터 체인에서 실행된다 | 가장 앞에서 거부한다. Spring MVC를 거치지 않는 요청도 대상이 된다 | 어느 컨트롤러 메서드로 갈 요청인지 모른다 |
| B. HandlerInterceptor | DispatcherServlet이 핸들러를 찾은 뒤 `preHandle`에서 실행된다 | 핸들러나 애너테이션별로 한도를 다르게 줄 수 있다 | 핸들러를 찾는 데까지의 비용은 이미 치른 뒤다 |
| C. AOP (`@RateLimited` 같은 애너테이션) | 컨트롤러 메서드의 프록시에서 실행된다 | 메서드 단위로 선언할 수 있다 | 인자 바인딩과 검증까지 끝난 뒤에야 거부한다. HTTP 응답을 직접 다루기 번거롭다 |

고른 이유: 처리율 제한의 목적은 서버가 일을 하기 전에 돌려보내는 것이다. 거부가 앞에서 일어날수록 거부된 요청에 드는 비용이 작다. URL 패턴 단위의 제한이면 핸들러 정보가 필요하지 않다.

다시 볼 시점: 엔드포인트별로 한도를 다르게 주고 싶어지면 B를 검토한다. 이 프로젝트의 범위에는 없다.

### 결정 2. 시계를 주입받는다 (`core/FixedWindowRateLimiter.java:21-29`, `web/RateLimitConfig.java:19-22`)

| 방식 | 동작 | 얻는 것 | 치르는 것 |
|---|---|---|---|
| A. `System.currentTimeMillis()`를 직접 호출 | 코어 안에서 시스템 시계를 바로 읽는다 | 코드가 짧다 | 윈도가 넘어가는 테스트를 하려면 실제로 기다려야 한다 |
| B. `java.time.Clock` 주입 (선택) | 생성자로 받은 시계의 `millis()`를 읽는다 | 테스트에서 시간을 손으로 움직인다. 시계를 바꿔 끼울 수 있다 | 생성자 인자가 하나 늘어난다 |

고른 이유: 윈도 경계를 넘는 동작이 이 알고리즘의 핵심인데, A로는 그 테스트가 10초씩 걸리거나 `sleep`에 의존하게 된다. `RateLimitFilterTest`도 실제 시계를 쓰면 테스트 도중에 윈도가 바뀔 수 있어서 고정된 시계를 `@Primary` 빈으로 넣었다.

다시 볼 시점: M3. 지금은 벽시계(`Clock.systemUTC()`)를 읽는다. 처리율 제한에 어떤 시계를 읽는 것이 맞는지는 토큰 버킷을 만들 때 다룬다.

### 결정 3. 윈도의 시작을 어디에 맞추는가 (`core/FixedWindowRateLimiter.java:47-52`)

| 방식 | 동작 |
|---|---|
| A. epoch 정렬 (기본값) | `now - (now % windowMillis)`. 10초 윈도면 시계의 00, 10, 20초에 모든 키의 윈도가 같이 바뀐다 |
| B. first-request 정렬 | 키의 첫 요청 시각에 윈도를 연다. 윈도가 끝난 뒤의 첫 요청이 다음 윈도를 연다 |

두 방식 모두 설정(`ratelimit.alignment`)으로 고를 수 있게 해 두었다. 무엇이 달라지는지는 예측 질문 2에서 다루고, 얻는 것과 치르는 것은 실험 뒤에 채운다.

### 결정 4. 상태를 어떻게 들고 있는가 (`core/FixedWindowRateLimiter.java:19`, `:54-62`)

| 방식 | 동작 | 얻는 것 | 치르는 것 |
|---|---|---|---|
| A. `HashMap<String, Window>` + `int count`, 동기화 없음 (선택) | 키로 `Window`를 찾아 `count`를 비교하고 올린다 | 알고리즘이 그대로 보이는 가장 짧은 코드 | 여러 스레드가 같은 상태를 만질 때의 동작을 보장하지 않는다. 키가 지워지지 않는다 |
| B. 처음부터 동시성 자료구조와 원자적 갱신 | `ConcurrentHashMap`, `AtomicInteger`, 락 등 | 동시 호출에 대한 보장 | 어떤 보장이 왜 필요한지 보기 전에 답부터 들어간다 |

고른 이유: M1은 끝에서 끝까지 도는 가장 얇은 구현이 목표다. 동시 요청에서 실제로 무슨 일이 생기는지 M2에서 먼저 관측하고 나서 고친다.

다시 볼 시점: M2(동시 호출), M4(키 정리).

### 결정 5. 클라이언트를 무엇으로 구분하는가 (`web/RateLimitFilter.java:55-61`)

| 방식 | 동작 | 얻는 것 | 치르는 것 |
|---|---|---|---|
| A. `X-Api-Key`, 없으면 `getRemoteAddr()` (선택) | 헤더 값이나 TCP 연결의 상대 IP를 키로 쓴다 | 인증 체계 없이도 실험에서 클라이언트를 여러 개 흉내 낼 수 있다 | 프록시 뒤에서는 모든 요청의 IP가 프록시 IP로 보인다 |
| B. `X-Forwarded-For`의 첫 값 | 프록시가 적어 준 원래 클라이언트 IP를 쓴다 | 프록시 뒤에서도 클라이언트를 구분한다 | 클라이언트가 헤더를 직접 써서 보낼 수 있다. 신뢰할 프록시를 정해야 한다 |
| C. 인증된 사용자 ID | 인증 필터 뒤에서 사용자 식별자를 쓴다 | 가장 정확하다 | 인증이 끝난 뒤에야 제한할 수 있다 |

고른 이유: 이 프로젝트에는 인증이 없고, 실험에서 키를 자유롭게 바꿀 수 있어야 한다. 키 앞에 `key:`와 `ip:`를 붙여서 API 키 값이 우연히 IP 문자열과 같아도 섞이지 않게 했다.

### 결정 6. 거부를 어떻게 알리는가 (`web/RateLimitFilter.java:41-53`)

상태 코드는 429다. RFC 6585 4절은 429를 "주어진 시간 동안 너무 많은 요청을 보냈다"는 뜻으로 정의하고, 응답에 얼마나 기다려야 하는지를 알리는 `Retry-After` 헤더를 넣을 수 있다고(MAY) 적는다(문서: https://www.rfc-editor.org/rfc/rfc6585.txt 4절, 2026-09-20 확인).

`X-RateLimit-*` 헤더는 표준이 아니라 여러 공개 API가 쓰는 관례다. `X-RateLimit-Reset`은 절대 시각이 아니라 남은 초로 주었다. 클라이언트와 서버의 시계가 달라도 뜻이 변하지 않는다. `Retry-After`와 `X-RateLimit-Reset`은 밀리초를 초로 올림한 값이다(`Decision.java:16-18`). 내림하면 클라이언트가 안내대로 기다렸는데도 다시 거부될 수 있다.

## 막혔던 곳

실험 스크립트를 처음 쓸 때 본문을 `{ ... } | tee` 로 묶었다. 파이프의 왼쪽은 서브셸에서 돌기 때문에 그 안에서 넣은 `SERVER_PID`가 바깥의 `trap cleanup`에 보이지 않고, 스크립트가 끝나도 서버가 남는 구조였다. 실행 전에 발견해서 `exec > >(tee "$OUT") 2>&1`로 바꿨다(`experiments/m1-worker-threads.sh:62-63`).

서버가 떴는지 확인하는 방법도 골라야 했다. 포트에 접속해 보는 방식은 그 접속을 서버가 받아 처리하므로 "요청이 하나도 오기 전" 상태를 관측하려는 실험 1에 섞인다. 서버 로그의 `Started RateLimiterApplication` 줄을 기다리는 방식으로 했다(`experiments/lib.sh:25-43`).
