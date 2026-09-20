package com.vryez.ratelimiter.core;

public enum WindowAlignment {

	/** 윈도 경계를 시계에 맞춘다. 10초 윈도면 매 분 00, 10, 20초에 모든 키의 윈도가 같이 바뀐다. */
	EPOCH,

	/** 키마다 첫 요청이 들어온 시각에 윈도를 연다. 윈도가 끝난 뒤 첫 요청이 다음 윈도를 연다. */
	FIRST_REQUEST
}
