package com.vryez.ratelimiter.core;

public interface RateLimiter {

	Decision tryAcquire(String key);
}
