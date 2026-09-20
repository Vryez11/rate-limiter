#!/usr/bin/env bash
# M1 실험 2. 윈도가 끝나는 시점 앞뒤로 요청 묶음을 보낸다. (limit=5, window=10s)
#
#   --align epoch (기본)     R = 다음 윈도 경계(시계의 10초 단위)
#                            A: R-1.0s에 5개, B: R+1.0s에 5개, C: B 직후 5개
#   --align first-request    R = 첫 요청 시각 (이 키의 윈도가 열리는 시점)
#                            A1: R에 1개, A2: R+9.0s에 4개, B: R+10.2s에 5개, C: B 직후 5개
#
# --schedule two-bursts|edge 로 일정만 따로 고를 수 있다. 생략하면 epoch은 two-bursts(위의 A/B/C),
# first-request는 edge(위의 A1/A2/B/C)를 쓴다.
#
# 사용법: experiments/m1-window-boundary.sh [--align epoch|first-request] [--schedule two-bursts|edge]
#         experiments/m1-window-boundary.sh --check   배선 점검. 경계를 넘지 않는 짧은 일정으로 같은 경로를 통과시킨다
set -euo pipefail
cd "$(dirname "$0")/.."
. experiments/lib.sh

ALIGN=epoch
SCHEDULE=""
MODE=run
while [ $# -gt 0 ]; do
	case "$1" in
		--align) ALIGN="$2"; shift 2 ;;
		--schedule) SCHEDULE="$2"; shift 2 ;;
		--check) MODE=check; shift ;;
		*) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
	esac
done

case "$ALIGN" in
	epoch|first-request) ;;
	*) echo "--align 은 epoch 또는 first-request" >&2; exit 2 ;;
esac
if [ -z "$SCHEDULE" ]; then
	if [ "$ALIGN" = "epoch" ]; then SCHEDULE=two-bursts; else SCHEDULE=edge; fi
fi

PORT=18081
URL="http://localhost:$PORT/api/ping"
LIMIT=5
WINDOW_MS=10000
KEY="boundary-$$"
mkdir -p "$TMP" experiments/results
LOG="$TMP/m1-window-boundary.server.log"
ROWS="$TMP/m1-window-boundary.rows.txt"
: > "$ROWS"

if [ "$MODE" = "check" ]; then
	OUT="$TMP/m1-window-boundary.check.txt"
else
	OUT="experiments/results/m1-window-boundary.$ALIGN.$SCHEDULE.$(date +%Y-%m-%d).txt"
fi

cleanup() {
	stop_server
	rm -f "$ROWS"
	if [ "$MODE" = "check" ]; then
		rm -f "$LOG" "$OUT"
	fi
}
trap cleanup EXIT

REF=0

# send_batch <라벨> <개수>: 요청을 연달아 보내고 한 줄씩 기록한다
send_batch() {
	local label="$1" count="$2" i=0 t resp status remaining retry
	while [ "$i" -lt "$count" ]; do
		i=$((i + 1))
		t=$(now_ms)
		resp=$(curl -s -o /dev/null -D - -H "X-Api-Key: $KEY" "$URL" | tr -d '\r')
		status=$(printf '%s\n' "$resp" | awk 'NR==1 { print $2 }')
		remaining=$(printf '%s\n' "$resp" | awk -F': ' 'tolower($1) == "x-ratelimit-remaining" { print $2 }')
		retry=$(printf '%s\n' "$resp" | awk -F': ' 'tolower($1) == "retry-after" { print $2 }')
		printf '%s %d %s %s %s\n' "$label" "$((t - REF))" "$status" "${remaining:--}" "${retry:--}" >> "$ROWS"
	done
}

print_rows() {
	printf '%-6s %10s %7s %10s %12s\n' batch "t-R(ms)" status remaining retry-after
	awk '{ printf "%-6s %10d %7s %10s %12s\n", $1, $2, $3, $4, $5 }' "$ROWS"
}

# summary <구간 시작(ms, R 기준)> <구간 끝>
summary() {
	local lo="$1" hi="$2"
	echo
	echo "묶음별 200 응답 수:"
	awk '$3 == 200 { ok[$1]++ } { seen[$1] = 1; if (!($1 in order)) { order[$1] = ++n; name[n] = $1 } }
		END { for (i = 1; i <= n; i++) printf "  %s: %d\n", name[i], ok[name[i]] + 0 }' "$ROWS"
	printf 'R%+dms ~ R%+dms 구간(%d초)에서 200 응답 수 (limit=%d):\n' "$lo" "$hi" "$(( (hi - lo) / 1000 ))" "$LIMIT"
	awk -v lo="$lo" -v hi="$hi" '$2 >= lo && $2 <= hi && $3 == 200 { n++ } END { printf "  %d\n", n + 0 }' "$ROWS"
}

exec > >(tee "$OUT") 2>&1

echo "# m1-window-boundary ($MODE, align=$ALIGN, schedule=$SCHEDULE) $(date '+%Y-%m-%d %H:%M:%S')"
echo "# limit=$LIMIT window=${WINDOW_MS}ms key=$KEY"
build_jar_if_missing
start_server "$LOG" --server.port=$PORT --ratelimit.limit=$LIMIT --ratelimit.window=${WINDOW_MS}ms --ratelimit.alignment=$ALIGN
echo "# server pid=$SERVER_PID port=$PORT"
echo

if [ "$MODE" = "check" ]; then
	# 한도 안쪽의 요청 2개만, 0.3초 기다렸다가 보낸다. 시각 계산, 대기, 헤더 파싱, 표, 집계가 도는지만 본다.
	REF=$(( $(now_ms) + 300 ))
	sleep_until_ms "$REF"
	send_batch chk 2
	print_rows
	summary -100 1000
	NOW=$(now_ms)
	echo "다음 epoch 경계까지: $(( (NOW / WINDOW_MS + 1) * WINDOW_MS - NOW ))ms"
	exit 0
fi

case "$SCHEDULE" in
	two-bursts)
		NOW=$(now_ms)
		REF=$(( (NOW / WINDOW_MS + 1) * WINDOW_MS ))
		# 경계가 너무 가까우면 A를 제때 못 보내므로 다음 경계를 쓴다
		if [ $((REF - NOW)) -lt 2500 ]; then
			REF=$((REF + WINDOW_MS))
		fi
		echo "R = 시계의 10초 경계 $(date -r $((REF / 1000)) '+%H:%M:%S') (지금부터 $((REF - NOW))ms 뒤)"
		sleep_until_ms $((REF - 1000)); send_batch A 5
		sleep_until_ms $((REF + 1000)); send_batch B 5
		send_batch C 5
		print_rows
		summary -1500 1500
		;;
	edge)
		REF=$(( $(now_ms) + 300 ))
		echo "R = 첫 요청 시각"
		sleep_until_ms "$REF"; send_batch A1 1
		sleep_until_ms $((REF + 9000)); send_batch A2 4
		sleep_until_ms $((REF + 10200)); send_batch B 5
		send_batch C 5
		print_rows
		summary 8500 11500
		;;
	*)
		echo "--schedule 은 two-bursts 또는 edge" >&2
		exit 2
		;;
esac

echo
echo "결과: $OUT"
