# Changelog

## [0.3.0](https://github.com/joshrotenberg/ex_resilience/compare/v0.2.0...v0.3.0) (2026-04-06)


### Features

* add adaptive concurrency limiter with AIMD and Vegas algorithms ([#22](https://github.com/joshrotenberg/ex_resilience/issues/22)) ([34eb1fc](https://github.com/joshrotenberg/ex_resilience/commit/34eb1fccf144986ad094322d1649f787a57711a5))
* add supervision tree integration and use macro ([#20](https://github.com/joshrotenberg/ex_resilience/issues/20)) ([bfa9c33](https://github.com/joshrotenberg/ex_resilience/commit/bfa9c33f3a3223c68b5ff8f778ebdf0fd28ec195))
* add unified error classifier behaviour ([#21](https://github.com/joshrotenberg/ex_resilience/issues/21)) ([a7e9ec0](https://github.com/joshrotenberg/ex_resilience/commit/a7e9ec05fb2582af31920828c5849eb8ee0d1930)), closes [#16](https://github.com/joshrotenberg/ex_resilience/issues/16)


### Bug Fixes

* bulkhead race condition in permit acquisition ([#24](https://github.com/joshrotenberg/ex_resilience/issues/24)) ([ec951fd](https://github.com/joshrotenberg/ex_resilience/commit/ec951fdda4497e4b32c0825fe43517a38eb178a5))

## [0.2.0](https://github.com/joshrotenberg/ex_resilience/compare/v0.1.0...v0.2.0) (2026-04-06)


### Features

* add coalesce (singleflight) layer ([5d44e4e](https://github.com/joshrotenberg/ex_resilience/commit/5d44e4e2222ac1861855344564737bbdfabcd725))
* add coalesce (singleflight) layer for request deduplication ([e99af9e](https://github.com/joshrotenberg/ex_resilience/commit/e99af9e910f4f67682f7eb8aa775dc93c64f02a0))
* add hedge, chaos, fallback, and cache layers ([f9ad33c](https://github.com/joshrotenberg/ex_resilience/commit/f9ad33c086ae37a1471c599220d4e28ce21c1441))
* add hedge, chaos, fallback, and cache layers ([fb184fd](https://github.com/joshrotenberg/ex_resilience/commit/fb184fd5162486ef5b8d946e85ab43e87fa941f7))
* add README, benchmarks, stress tests, and examples ([#14](https://github.com/joshrotenberg/ex_resilience/issues/14)) ([166b4c3](https://github.com/joshrotenberg/ex_resilience/commit/166b4c3fef29c81bd97205c682262d6d00b29163))
* implement core resilience patterns (bulkhead, circuit breaker, retry, rate limiter) ([c7d7c38](https://github.com/joshrotenberg/ex_resilience/commit/c7d7c383b1b6bd6fbabcfe2c62300e6ec20eef36))
* scaffold ex_resilience project with research context ([a632079](https://github.com/joshrotenberg/ex_resilience/commit/a632079e0fea6830c4589526bfca9734f7bf21ef))
