package com.vryez.ratelimiter.core;

/**
 * @param resetAfterMillis 한도가 다시 채워질 때까지 남은 시간. 거부된 요청에는 이 값이 Retry-After가 된다.
 */
public record Decision(boolean allowed, int limit, int remaining, long resetAfterMillis) {

	public static Decision allowed(int limit, int remaining, long resetAfterMillis) {
		return new Decision(true, limit, remaining, resetAfterMillis);
	}

	public static Decision denied(int limit, long resetAfterMillis) {
		return new Decision(false, limit, 0, resetAfterMillis);
	}

	public long resetAfterSeconds() {
		return (resetAfterMillis + 999) / 1000;
	}
}
