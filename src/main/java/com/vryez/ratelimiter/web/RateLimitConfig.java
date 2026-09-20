package com.vryez.ratelimiter.web;

import java.time.Clock;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;

import com.vryez.ratelimiter.core.FixedWindowRateLimiter;
import com.vryez.ratelimiter.core.RateLimiter;

@Configuration
@EnableConfigurationProperties(RateLimitProperties.class)
public class RateLimitConfig {

	@Bean
	Clock clock() {
		return Clock.systemUTC();
	}

	@Bean
	RateLimiter rateLimiter(RateLimitProperties properties, Clock clock) {
		return new FixedWindowRateLimiter(properties.limit(), properties.window(), properties.alignment(), clock);
	}

	@Bean
	@ConditionalOnProperty(prefix = "ratelimit", name = "enabled", havingValue = "true", matchIfMissing = true)
	FilterRegistrationBean<RateLimitFilter> rateLimitFilter(RateLimiter rateLimiter) {
		FilterRegistrationBean<RateLimitFilter> registration = new FilterRegistrationBean<>(new RateLimitFilter(rateLimiter));
		registration.addUrlPatterns("/api/*");
		// 한도를 넘은 요청은 다른 필터가 일하기 전에 돌려보낸다
		registration.setOrder(Ordered.HIGHEST_PRECEDENCE + 10);
		return registration;
	}
}
