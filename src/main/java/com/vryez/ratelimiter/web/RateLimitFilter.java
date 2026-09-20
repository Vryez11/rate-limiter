package com.vryez.ratelimiter.web;

import java.io.IOException;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.web.filter.OncePerRequestFilter;

import com.vryez.ratelimiter.core.Decision;
import com.vryez.ratelimiter.core.RateLimiter;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

public class RateLimitFilter extends OncePerRequestFilter {

	static final String API_KEY_HEADER = "X-Api-Key";

	private static final Logger log = LoggerFactory.getLogger(RateLimitFilter.class);

	private final RateLimiter rateLimiter;

	public RateLimitFilter(RateLimiter rateLimiter) {
		this.rateLimiter = rateLimiter;
	}

	@Override
	protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
			throws ServletException, IOException {
		String key = resolveKey(request);
		Decision decision = rateLimiter.tryAcquire(key);

		// remotePort는 클라이언트 쪽 포트라서 TCP 연결을 구분하는 값으로 쓸 수 있다
		log.debug("key={} allowed={} remaining={} remotePort={} thread={}", key, decision.allowed(),
				decision.remaining(), request.getRemotePort(), Thread.currentThread().getName());

		response.setIntHeader("X-RateLimit-Limit", decision.limit());
		response.setIntHeader("X-RateLimit-Remaining", decision.remaining());
		response.setHeader("X-RateLimit-Reset", Long.toString(decision.resetAfterSeconds()));

		if (decision.allowed()) {
			chain.doFilter(request, response);
			return;
		}
		response.setStatus(HttpStatus.TOO_MANY_REQUESTS.value());
		response.setHeader("Retry-After", Long.toString(decision.resetAfterSeconds()));
		response.setContentType(MediaType.APPLICATION_JSON_VALUE);
		response.getWriter().write("{\"error\":\"too_many_requests\",\"retryAfterSeconds\":" + decision.resetAfterSeconds() + "}");
	}

	private String resolveKey(HttpServletRequest request) {
		String apiKey = request.getHeader(API_KEY_HEADER);
		if (apiKey != null && !apiKey.isBlank()) {
			return "key:" + apiKey;
		}
		return "ip:" + request.getRemoteAddr();
	}
}
