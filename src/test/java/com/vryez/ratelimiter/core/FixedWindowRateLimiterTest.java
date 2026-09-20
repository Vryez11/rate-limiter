package com.vryez.ratelimiter.core;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Duration;

import org.junit.jupiter.api.Test;

class FixedWindowRateLimiterTest {

	private static final Duration WINDOW = Duration.ofSeconds(10);

	// 10초 윈도의 경계(…0000ms)에서 3초 지난 시각
	private final MutableClock clock = new MutableClock(1_000_003_000L);

	@Test
	void 한도까지는_허용하고_남은_수를_알려준다() {
		RateLimiter limiter = new FixedWindowRateLimiter(3, WINDOW, WindowAlignment.EPOCH, clock);

		assertThat(limiter.tryAcquire("a")).isEqualTo(Decision.allowed(3, 2, 7_000));
		assertThat(limiter.tryAcquire("a")).isEqualTo(Decision.allowed(3, 1, 7_000));
		assertThat(limiter.tryAcquire("a")).isEqualTo(Decision.allowed(3, 0, 7_000));
	}

	@Test
	void 한도를_넘으면_거부하고_윈도가_끝날_때까지_남은_시간을_알려준다() {
		RateLimiter limiter = new FixedWindowRateLimiter(1, WINDOW, WindowAlignment.EPOCH, clock);
		limiter.tryAcquire("a");
		clock.advance(Duration.ofMillis(2_500));

		Decision decision = limiter.tryAcquire("a");

		assertThat(decision).isEqualTo(Decision.denied(1, 4_500));
		assertThat(decision.resetAfterSeconds()).isEqualTo(5);
	}

	@Test
	void 키가_다르면_따로_센다() {
		RateLimiter limiter = new FixedWindowRateLimiter(1, WINDOW, WindowAlignment.EPOCH, clock);

		assertThat(limiter.tryAcquire("a").allowed()).isTrue();
		assertThat(limiter.tryAcquire("a").allowed()).isFalse();
		assertThat(limiter.tryAcquire("b").allowed()).isTrue();
	}

	@Test
	void 윈도가_지나면_다시_허용한다() {
		RateLimiter limiter = new FixedWindowRateLimiter(1, WINDOW, WindowAlignment.EPOCH, clock);
		limiter.tryAcquire("a");
		assertThat(limiter.tryAcquire("a").allowed()).isFalse();

		clock.advance(WINDOW);

		assertThat(limiter.tryAcquire("a").allowed()).isTrue();
	}

	@Test
	void first_request_정렬은_첫_요청_시각부터_윈도를_센다() {
		RateLimiter limiter = new FixedWindowRateLimiter(1, WINDOW, WindowAlignment.FIRST_REQUEST, clock);

		assertThat(limiter.tryAcquire("a")).isEqualTo(Decision.allowed(1, 0, 10_000));
		clock.advance(Duration.ofSeconds(4));
		assertThat(limiter.tryAcquire("a")).isEqualTo(Decision.denied(1, 6_000));
	}

	@Test
	void limit과_window는_양수여야_한다() {
		assertThatThrownBy(() -> new FixedWindowRateLimiter(0, WINDOW, WindowAlignment.EPOCH, clock))
				.isInstanceOf(IllegalArgumentException.class);
		assertThatThrownBy(() -> new FixedWindowRateLimiter(1, Duration.ZERO, WindowAlignment.EPOCH, clock))
				.isInstanceOf(IllegalArgumentException.class);
	}
}
