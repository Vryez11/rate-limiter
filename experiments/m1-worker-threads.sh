#!/usr/bin/env bash
# M1 실험 1. 필터를 실행하는 스레드를 본다.
#
#   1) 서버가 뜬 직후, 요청이 하나도 오기 전의 스레드 덤프
#   2) 요청 5개를 매번 새 TCP 연결로 보낸다 (curl 프로세스 5번)
#   3) 요청 5개를 한 TCP 연결로 보낸다 (curl 한 번에 URL 5개, keep-alive)
#   4) 요청을 보낸 뒤의 스레드 덤프
#
# 사용법: experiments/m1-worker-threads.sh          본 실험. 결과를 experiments/results/에 남긴다
#         experiments/m1-worker-threads.sh --check  배선 점검. 값은 출력하지 않고 형식만 확인한다
set -euo pipefail
cd "$(dirname "$0")/.."
. experiments/lib.sh

MODE="${1:-run}"
PORT=18080
URL="http://localhost:$PORT/api/ping"
mkdir -p "$TMP" experiments/results
LOG="$TMP/m1-worker-threads.server.log"

if [ "$MODE" = "--check" ]; then
	OUT="$TMP/m1-worker-threads.check.txt"
	# 점검에서는 어느 JVM에나 있는 스레드 이름으로 같은 파이프라인을 통과시킨다
	EXEC_PATTERN='^"Reference Handler'
	CONNECTOR_PATTERN='^"(Finalizer|Signal Dispatcher)"'
else
	OUT="experiments/results/m1-worker-threads.$(date +%Y-%m-%d).txt"
	EXEC_PATTERN="^\"http-nio-$PORT-exec-"
	CONNECTOR_PATTERN="^\"http-nio-$PORT-[A-Za-z]+\""
fi

cleanup() {
	stop_server
	if [ "$MODE" = "--check" ]; then
		rm -f "$LOG" "$TMP"/m1-worker-threads.dump*.txt "$OUT"
	fi
}
trap cleanup EXIT

thread_summary() {
	local dump="$1"
	echo "JVM 전체 스레드 수: $(grep -c '^"' "$dump")"
	echo "요청 처리 스레드 수 (패턴 $EXEC_PATTERN): $(grep -cE "$EXEC_PATTERN" "$dump" || true)"
	echo "커넥터의 그 밖의 스레드:"
	grep -oE "$CONNECTOR_PATTERN" "$dump" | grep -v -- '-exec-' | sed 's/^/  /' || true
}

# 서버 로그에서 필터의 DEBUG 줄만 뽑는다. 점검 모드에서는 값 대신 필드가 다 있는지만 말한다.
filter_lines() {
	local key="$1"
	local lines
	lines=$(grep 'RateLimitFilter' "$LOG" | grep "key=key:$key " | sed -E 's/^.*(key=key:)/\1/' || true)
	if [ "$MODE" = "--check" ]; then
		printf '%s\n' "$lines" | awk '
			/remotePort=[0-9]+/ && /thread=[^ ]+/ { ok++ }
			END { printf "  로그 %d줄, 필드(remotePort, thread)를 갖춘 줄 %d\n", NR, ok }'
	else
		printf '%s\n' "$lines" | sed 's/^/  /'
	fi
}

# 파이프로 tee에 넘기면 본문이 서브셸에서 돌아 SERVER_PID가 trap에 보이지 않는다
exec > >(tee "$OUT") 2>&1

echo "# m1-worker-threads ($MODE) $(date '+%Y-%m-%d %H:%M:%S')"
echo "# $("$JAVA" -version 2>&1 | head -1), $(uname -sm)"
build_jar_if_missing
start_server "$LOG" --server.port=$PORT --ratelimit.limit=1000 --logging.level.com.vryez.ratelimiter=DEBUG
echo "# server pid=$SERVER_PID port=$PORT"
echo

echo "## 1. 요청이 오기 전"
"$JCMD" "$SERVER_PID" Thread.print > "$TMP/m1-worker-threads.dump1.txt"
thread_summary "$TMP/m1-worker-threads.dump1.txt"
echo

echo "## 2. 요청 5개, 매번 새 연결"
for i in 1 2 3 4 5; do
	curl -s -o /dev/null -H 'X-Api-Key: new-conn' "$URL"
done
sleep 0.3
filter_lines new-conn
echo

echo "## 3. 요청 5개, 한 연결 (keep-alive)"
reused=$(curl -sv -H 'X-Api-Key: keep-alive' "$URL" "$URL" "$URL" "$URL" "$URL" 2>&1 >/dev/null | grep -ci 're-using existing connection' || true)
echo "  curl이 연결을 재사용한 횟수: $reused"
sleep 0.3
filter_lines keep-alive
echo

echo "## 4. 요청을 보낸 뒤"
"$JCMD" "$SERVER_PID" Thread.print > "$TMP/m1-worker-threads.dump2.txt"
thread_summary "$TMP/m1-worker-threads.dump2.txt"

if [ "$MODE" != "--check" ]; then
	cp "$TMP/m1-worker-threads.dump1.txt" "experiments/results/m1-worker-threads.dump-before.$(date +%Y-%m-%d).txt"
	cp "$TMP/m1-worker-threads.dump2.txt" "experiments/results/m1-worker-threads.dump-after.$(date +%Y-%m-%d).txt"
	echo
	echo "결과: $OUT (스레드 덤프 원문은 같은 폴더의 m1-worker-threads.dump-*.txt)"
fi
