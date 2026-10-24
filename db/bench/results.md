# Milestone 0 results

Run 2026-10-24 11:18 UTC by `npm run db:bench`. Database x86_64/Linux 2.4.xx at 10.127.148.250:1521/FREEPDB1; Node on MacBook-Pro.local (darwin), which is what B6 measures.

Median, with the fastest and slowest run in brackets.

| Benchmark | interpreted | native (not available) |
| --- | --- | --- |
| B1 loop, per iteration | 6 ns (6–6) | – |
| B2 BINARY_DOUBLE, per operation | 11 ns (10–11) | – |
| B2 NUMBER, per operation | 84 ns (84–84) | – |
| B3 associative array, per random read | 109 ns (93–122) | – |
| B3 nested table, per random read | 106 ns (94–119) | – |
| B3 VARRAY, per random read | 97 ns (70–115) | – |
| B4 fake frame, 640 columns × 71 steps (≤ 15 ms) | 12.2 ms (5.7–13.7) | – |
| B5 pack 15,360 runs (≤ 5 ms) | 5.2 ms (2.8–6.1) | – |
| **B4 + B5 at 640×360 (≤ 25 ms)** | **17.4 ms** | – |
| B4 + B5 at 320×180 | 10.1 ms | – |
| B4 + B5 at 256×144, view distance 32 | 6.9 ms | – |
| Recording 15,360 runs (counts toward the renderer) | 8.4 ms (5.0–9.9) | – |

NATIVE could not compile: PC_BENCH line 0: ORA-06590: PL/SQL: Native mode requires execute privileges on the shared memory object directory

B3 memory for 1,048,576 elements (limit 100 MB): associative array 29.7 MB, nested table 29.7 MB, VARRAY 26.2 MB.

B6 round trip, 75000 bytes, 1,000 calls: p50 21.1 ms, p95 29.0 ms (≤ 3 ms), max 58.2 ms.

## Decisions, from interpreted (NATIVE can only be faster)

- B2: BINARY_DOUBLE is 7.6× faster than NUMBER, so NUMBER stays out of hot code.
- B3: the VARRAY holds the block array and the span cache. Rounds of 9 faster than the associative array: nested table 5, VARRAY 8 (a change needs 6).
- B4 + B5 = 17.4 ms at 640×360: Build at 640×360, view distance 48.
- B6: over budget. Run Node on the database machine and measure again.
