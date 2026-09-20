# 실험 스크립트 공통 함수. source해서 쓴다.
# macOS 기본 bash 3.2에서 돌아가야 한다.

export JAVA_HOME="$(/usr/libexec/java_home -v 21)"
JAVA="$JAVA_HOME/bin/java"
JCMD="$JAVA_HOME/bin/jcmd"
JAR=build/libs/rate-limiter-0.0.1-SNAPSHOT.jar
TMP=experiments/.tmp
SERVER_PID=""

now_ms() {
	perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'
}

sleep_until_ms() {
	perl -MTime::HiRes=time,sleep -e '$d = ($ARGV[0] / 1000) - time(); sleep($d) if $d > 0' "$1"
}

build_jar_if_missing() {
	if [ ! -f "$JAR" ] || [ -n "$(find src/main -newer "$JAR" -type f | head -1)" ]; then
		./gradlew bootJar -q
	fi
}

# start_server <log 파일> <서버 인자...>
# 기동 확인은 로그로 한다. 포트에 접속해서 확인하면 그 접속도 서버가 처리해서 관측에 섞인다.
start_server() {
	local log="$1"
	shift
	"$JAVA" -jar "$JAR" "$@" > "$log" 2>&1 &
	SERVER_PID=$!
	disown "$SERVER_PID" 2>/dev/null || true
	local i=0
	while ! grep -q "Started RateLimiterApplication" "$log" 2>/dev/null; do
		i=$((i + 1))
		if [ "$i" -gt 100 ] || ! kill -0 "$SERVER_PID" 2>/dev/null; then
			echo "서버가 뜨지 않았다. 로그: $log" >&2
			tail -20 "$log" >&2
			exit 1
		fi
		sleep 0.2
	done
}

stop_server() {
	if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
		kill "$SERVER_PID" 2>/dev/null || true
		local i=0
		while kill -0 "$SERVER_PID" 2>/dev/null && [ "$i" -lt 50 ]; do
			i=$((i + 1))
			sleep 0.1
		done
	fi
	SERVER_PID=""
}
