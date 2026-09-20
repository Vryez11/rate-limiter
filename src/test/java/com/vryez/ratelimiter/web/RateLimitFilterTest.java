package com.vryez.ratelimiter.web;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.time.Clock;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;
import org.springframework.test.web.servlet.MockMvc;

import com.vryez.ratelimiter.core.MutableClock;

@SpringBootTest(properties = { "ratelimit.limit=2", "ratelimit.window=10s" })
@AutoConfigureMockMvc
class RateLimitFilterTest {

	@TestConfiguration
	static class FixedClockConfig {

		// 실제 시계를 쓰면 테스트 도중 윈도가 바뀔 수 있다. 경계에서 3초 지난 시각에 고정한다.
		@Bean
		@Primary
		Clock testClock() {
			return new MutableClock(1_000_003_000L);
		}
	}

	@Autowired
	MockMvc mockMvc;

	@Test
	void 한도까지는_200과_남은_수_헤더를_준다() throws Exception {
		mockMvc.perform(get("/api/ping").header("X-Api-Key", "within-limit"))
				.andExpect(status().isOk())
				.andExpect(jsonPath("$.message").value("pong"))
				.andExpect(header().string("X-RateLimit-Limit", "2"))
				.andExpect(header().string("X-RateLimit-Remaining", "1"))
				.andExpect(header().string("X-RateLimit-Reset", "7"));
	}

	@Test
	void 한도를_넘으면_429와_Retry_After를_준다() throws Exception {
		for (int i = 0; i < 2; i++) {
			mockMvc.perform(get("/api/ping").header("X-Api-Key", "over-limit")).andExpect(status().isOk());
		}

		mockMvc.perform(get("/api/ping").header("X-Api-Key", "over-limit"))
				.andExpect(status().isTooManyRequests())
				.andExpect(header().string("Retry-After", "7"))
				.andExpect(header().string("X-RateLimit-Remaining", "0"))
				.andExpect(jsonPath("$.error").value("too_many_requests"));
	}

	@Test
	void api_경로가_아니면_필터를_거치지_않는다() throws Exception {
		mockMvc.perform(get("/not-api"))
				.andExpect(status().isNotFound())
				.andExpect(header().doesNotExist("X-RateLimit-Limit"));
	}
}
