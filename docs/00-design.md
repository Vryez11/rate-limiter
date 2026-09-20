# 처리율 제한 장치 설계

## 만들려는 것

요청 원문: "처리율 제한 장치 설계 및 구현을 해줘."

HTTP API 앞에서 클라이언트별 요청 수를 세고, 한도를 넘으면 429를 돌려주는 장치로 해석했다. 알고리즘 코어는 Spring에 의존하지 않는 순수 Java로 두고, Spring Boot 쪽은 서블릿 필터 하나로 얇게 붙인다.

기본값으로 정한 것:

- 클라이언트 식별은 `X-Api-Key` 헤더, 없으면 접속 IP
- 한도를 넘으면 429와 `Retry-After`, 모든 응답에 `X-RateLimit-Limit/Remaining/Reset`
- 알고리즘, 한도, 윈도 크기는 `application.yml`로 바꾼다
- system-design-lab에서 직접 구현하기로 했던 과제와 주제가 겹친다. 모니터링(Prometheus, Grafana, k6)은 그쪽 실습 몫으로 남기고 여기서는 다루지 않는다

## 범위

하는 것:

- 알고리즘 4종: 고정 윈도 카운터, 토큰 버킷, 슬라이딩 윈도 로그, 슬라이딩 윈도 카운터
- 동시 요청에서의 정확성
- 안 쓰는 키의 상태 정리
- Redis로 서버 여러 대가 한도 하나를 공유

안 하는 것:

- 모니터링 대시보드, 규칙의 동적 리로드, API Gateway 연동
- 누출 버킷. 요청을 큐에 쌓아 일정 속도로 처리하는 구조라서 "통과/거부를 바로 판정하는 필터"와 모양이 다르다

## 스택

| 선택지 | 특징 | 이 프로젝트에서 |
|---|---|---|
| A. Spring Boot 필터 안에 전부 구현 | 가장 빨리 만든다 | 실험이 항상 HTTP를 거쳐서 측정에 잡음이 낀다 |
| B. 순수 Java 코어 + Spring Boot 필터 어댑터 (선택) | `core` 패키지에 Spring import가 없다 | 동시성, 자료구조 실험은 코어를 스레드로 직접 호출하고 HTTP 동작은 필터로 확인한다 |
| C. 프레임워크 없이 소켓 서버부터 | HTTP 서버까지 직접 만든다 | 이 주제의 CS 지점은 서버가 아니라 카운터, 시계, 자료구조 쪽이다 |

면접 스택인 Java 21과 Spring Boot를 유지하면서도 코어를 HTTP 없이 실험할 수 있어서 B를 골랐다. 모듈은 하나로 두고 패키지로만 나눈다. 버전은 backend-lab과 같은 Spring Boot 4.1.0, Gradle 9.5.1이다.

환경(2026-09-20 관측): JDK 21.0.11(셸 기본은 25라서 스크립트에서 21로 고정), Apple Silicon macOS, Docker 29.6.1(linux/aarch64, 커널 6.12.76-linuxkit), 부하 도구는 `ab`만 설치됨.

## 구조

```
client --HTTP--> Tomcat worker thread
                     |
                 RateLimitFilter                         web/  (Spring 어댑터)
                     |  key = X-Api-Key 또는 IP
                     v
                 RateLimiter.tryAcquire(key) --> Decision(allowed, remaining, resetAfter)
                     |                                   core/ (순수 Java)
       +-------------+---------------+---------------------+
  FixedWindow    TokenBucket    SlidingWindowLog/Counter   RedisRateLimiter (M5)
       |             |               |                          |
       +---- Map<key, state> (JVM 메모리) ----+               Redis (Docker)

  allowed -> chain.doFilter -> PingController -> 200
  denied  -> 429 + Retry-After
```

- `RateLimitFilter`: 요청에서 키를 뽑아 코어에 묻고, 결과를 헤더와 상태 코드로 옮긴다
- `RateLimiter`: 알고리즘이 구현하는 인터페이스. 메서드는 `tryAcquire(key)` 하나
- `Decision`: 통과 여부, 남은 수, 한도가 다시 채워질 때까지 남은 시간
- `PingController`: 제한 대상이 되는 예시 API

## 폴더 구조

```
~/Vryez11/rate-limiter/
├── build.gradle, settings.gradle, gradlew
├── src/main/java/com/vryez/ratelimiter/
│   ├── core/          RateLimiter, Decision, 알고리즘 구현 (Spring 의존 없음)
│   ├── web/           RateLimitFilter, RateLimitConfig, RateLimitProperties, PingController
│   └── RateLimiterApplication.java
├── src/main/resources/application.yml
├── src/test/java/...  단위 테스트, MockMvc 테스트
├── docs/              00-design.md, 01-*.md ..., cs-map.md
└── experiments/       실험 스크립트 (lib.sh, m1-*.sh ...)
    └── results/       실험 출력 원문 (커밋 대상)
```

## 마일스톤

| | 이름 | 끝나면 돌아가는 것 | 예상 CS 지점 |
|---|---|---|---|
| [ ] M1 | 고정 윈도 + 필터 | curl로 한도까지 200, 넘으면 429와 헤더. 상태는 가장 단순한 구현 | 윈도 경계에서의 동작, 필터가 도는 스레드 |
| [ ] M2 | 동시 요청 실험과 동기화 | 코어를 동시에 호출하는 실험 하네스, 동기화 방식별 구현 비교 | check-then-act 원자성, 락과 CAS |
| [ ] M3 | 토큰 버킷 | 설정으로 알고리즘 교체, 버스트와 리필 확인 | 시간을 어디서 읽는가(시계 종류), 리필 방식 |
| [ ] M4 | 슬라이딩 윈도 2종 + 키 만료 | 로그 방식과 카운터 방식 교체, 안 쓰는 키 정리 | 자료구조 선택과 키당 메모리 비용 |
| [ ] M5 | Redis 분산 제한 | 서버 2대가 한도 하나를 공유 (Docker 필요) | 네트워크 왕복, 원자성을 어디에 두는가 |

## 뒤 마일스톤으로 넘긴 것

- M2: `FixedWindowRateLimiter`는 `HashMap`과 동기화 없는 `count++`로 되어 있다. 이 상태를 출발점으로 쓴다 (M1 결정 4)
- M3: 시계를 `java.time.Clock`으로 주입받고 있다. 어떤 시계를 읽는 것이 맞는지 다시 본다 (M1 결정 2)
- M4: 키별 `Window` 객체가 맵에서 지워지지 않는다 (M1 결정 4)

## 진행 메모

- 2026-09-20: 설계 합의, M1 코드와 실험 스크립트 작성. 빌드와 테스트 9개 통과, curl로 200/429 확인. 두 실험 스크립트는 `--check`로 배선만 점검했고 본 실험은 아직 돌리지 않았다.
- GitHub 저장소: `Vryez11/rate-limiter` (비공개로 생성)
- 다음에 할 일: 아래 예측 질문의 답을 받은 뒤 M1 둘째 턴(실험, 계층 내려가기, 기록)

답을 기다리는 예측 질문 (M1):

1. 필터를 실행하는 스레드. 서버를 기본 설정으로 `java -jar`로 띄운다.
   - (a) 서버가 뜬 직후, 요청이 하나도 오기 전에 요청 처리용 스레드(`http-nio-18080-exec-N`)는 몇 개 떠 있을까?
   - (b) 요청 5개를 매번 새 TCP 연결로 보낼 때와 한 연결(keep-alive)로 보낼 때, 필터 로그의 스레드 이름은 각각 어떻게 나올까? (모두 같은 스레드 / 모두 다른 스레드 / 섞임)
   - 실험: `experiments/m1-worker-threads.sh`
2. 윈도 경계. limit=5, window=10초, epoch 정렬. 경계 시각 R을 기준으로 R-1초에 5개, R+1초에 5개, 그 직후 5개를 같은 키로 보낸다.
   - (a) 15개 중 몇 개가 200일까? R 앞뒤 3초 구간에서는 몇 개가 통과할까?
   - (b) 정렬을 first-request로 바꾸면 (a)의 결과가 달라질까? 달라진다면 그것으로 문제가 해결된 걸까?
   - 실험: `experiments/m1-window-boundary.sh`, 같은 스크립트에 `--align first-request`
