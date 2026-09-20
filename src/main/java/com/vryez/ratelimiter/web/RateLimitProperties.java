package com.vryez.ratelimiter.web;

import java.time.Duration;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.bind.DefaultValue;

import com.vryez.ratelimiter.core.WindowAlignment;

@ConfigurationProperties(prefix = "ratelimit")
public record RateLimitProperties(
		@DefaultValue("true") boolean enabled,
		@DefaultValue("5") int limit,
		@DefaultValue("10s") Duration window,
		@DefaultValue("epoch") WindowAlignment alignment) {
}
