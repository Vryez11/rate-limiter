package com.vryez.ratelimiter.core;

import java.time.Clock;
import java.time.Duration;
import java.util.HashMap;
import java.util.Map;

/**
 * 고정 윈도 카운터. 시간을 윈도 크기로 잘라 윈도마다 키별 요청 수를 센다.
 *
 * M1의 가장 단순한 구현이다. 동기화가 없다. 여러 스레드가 동시에 호출하는 상황은 M2에서 다룬다.
 */
public class FixedWindowRateLimiter implements RateLimiter {

	private final int limit;
	private final long windowMillis;
	private final WindowAlignment alignment;
	private final Clock clock;
	private final Map<String, Window> windows = new HashMap<>();

	public FixedWindowRateLimiter(int limit, Duration window, WindowAlignment alignment, Clock clock) {
		if (limit <= 0 || window.toMillis() <= 0) {
			throw new IllegalArgumentException("limit과 window는 0보다 커야 한다");
		}
		this.limit = limit;
		this.windowMillis = window.toMillis();
		this.alignment = alignment;
		this.clock = clock;
	}

	@Override
	public Decision tryAcquire(String key) {
		long now = clock.millis();
		Window window = windows.get(key);
		if (window == null || now >= window.start + windowMillis) {
			window = new Window(windowStart(now));
			windows.put(key, window);
		}
		long resetAfter = window.start + windowMillis - now;
		if (window.count >= limit) {
			return Decision.denied(limit, resetAfter);
		}
		window.count++;
		return Decision.allowed(limit, limit - window.count, resetAfter);
	}

	private long windowStart(long now) {
		return switch (alignment) {
			case EPOCH -> now - (now % windowMillis);
			case FIRST_REQUEST -> now;
		};
	}

	private static final class Window {

		final long start;
		int count;

		Window(long start) {
			this.start = start;
		}
	}
}
