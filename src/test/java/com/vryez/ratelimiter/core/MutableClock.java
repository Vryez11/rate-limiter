package com.vryez.ratelimiter.core;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;

/** 테스트에서 시간을 손으로 움직이기 위한 시계. */
public class MutableClock extends Clock {

	private long millis;

	public MutableClock(long startMillis) {
		this.millis = startMillis;
	}

	public void advance(Duration duration) {
		millis += duration.toMillis();
	}

	@Override
	public long millis() {
		return millis;
	}

	@Override
	public Instant instant() {
		return Instant.ofEpochMilli(millis);
	}

	@Override
	public ZoneId getZone() {
		return ZoneOffset.UTC;
	}

	@Override
	public Clock withZone(ZoneId zone) {
		return this;
	}
}
