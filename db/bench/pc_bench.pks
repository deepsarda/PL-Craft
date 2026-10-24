-- Milestone 0 benchmarks B1 to B5 (Section 4). Not part of the game: server/bench.js compiles this package,
-- runs it once INTERPRETED and once NATIVE, keeps the median of three runs of each, then drops it.
create or replace package pc_bench as

  -- B1: nanoseconds per iteration of i := i + 1 with SIMPLE_INTEGER, over 10 million iterations.
  function b1 return number;

  -- B2: nanoseconds per a := a * b + c, over 10 million iterations, in NUMBER or in BINARY_DOUBLE.
  function b2(p_number in boolean) return number;

  -- B3: fills a 1,048,576-element associative array, nested table and VARRAY (the world's size).
  procedure b3_fill;

  -- B3: nanoseconds per random read from one of them, 'AA', 'NT' or 'VA', over 10 million reads.
  function b3(p_kind in varchar2) return number;

  -- B3: bytes of session PGA that filling one of them takes. Call in a fresh session.
  function b3_memory(p_kind in varchar2) return number;

  -- B4: milliseconds for a fake frame of p_columns × p_steps DDA steps, each with one collection read and
  -- two BINARY_DOUBLE projections. The collection type comes from PLSQL_CCFLAGS b4_kind (1 AA, 2 NT, 3 VA).
  function b4(p_columns in pls_integer, p_steps in pls_integer) return number;

  -- B5: milliseconds for pc_frame to pack 24 runs in each of p_columns columns. p_part 'pack' times
  -- pc_frame.finish (hex text, HEXTORAW, BLOB appends); 'record' times the pc_frame.run calls.
  function b5(p_part in varchar2, p_columns in pls_integer) return number;

  -- B6: returns a 75 KB BLOB, for Node to call 1,000 times.
  procedure b6(p_frame out blob);

end pc_bench;
/
