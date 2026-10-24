create or replace package body pc_bench as

  c_loops constant simple_integer := 10000000;
  c_cells constant simple_integer := 1048576;   -- 128 × 64 × 128
  c_mul   constant simple_integer := 1664525;   -- LCG constants: SIMPLE_INTEGER arithmetic wraps instead of
  c_add   constant simple_integer := 1013904223; -- failing, and the low 20 bits visit every cell
  c_mask  constant simple_integer := 1048575;
  c_never constant binary_double := 1e30;

  type t_aa is table of pls_integer index by pls_integer;
  type t_nt is table of pls_integer;
  type t_va is varray(1048576) of pls_integer;

  $if $$b4_kind = 2 $then
  type t_cells is table of pls_integer;
  $elsif $$b4_kind = 3 $then
  type t_cells is varray(1048576) of pls_integer;
  $else
  type t_cells is table of pls_integer index by pls_integer;
  $end

  g_aa    t_aa;
  g_nt    t_nt := t_nt();
  g_va    t_va := t_va();
  g_cells t_cells := t_cells();
  g_b6    blob;

  -- Results land here, so the compiler cannot drop a loop as dead code.
  g_sink   simple_integer := 0;
  g_sink_d binary_double := 0;

  -- Elapsed milliseconds since p_start, for the short benchmarks (Section 4).
  function ms_since(p_start in timestamp with time zone) return number is
    l_took interval day to second := systimestamp - p_start;
  begin
    return (extract(minute from l_took) * 60 + extract(second from l_took)) * 1000;
  end ms_since;

  function pga return number is
    l_bytes number;
  begin
    select s.value into l_bytes
      from v$mystat s
      join v$statname n on n.statistic# = s.statistic#
     where n.name = 'session pga memory';
    return l_bytes;
  end pga;

  -- GET_CPU_TIME counts hundredths of a second: over 10 million iterations, one hundredth is 1 ns each.
  function ns_each(p_cpu_hundredths in number) return number is
  begin
    return p_cpu_hundredths * 1e7 / c_loops;
  end ns_each;

  function b1 return number is
    l_i  simple_integer := 0;
    l_t0 number := dbms_utility.get_cpu_time;
  begin
    for k in 1 .. c_loops loop
      l_i := l_i + 1;
    end loop;
    g_sink := l_i;
    return ns_each(dbms_utility.get_cpu_time - l_t0);
  end b1;

  function b2(p_number in boolean) return number is
    l_t0 number;
    l_a  binary_double := 0;
    l_b  binary_double := 0.999999d;
    l_c  binary_double := 0.5d;
    l_na number := 0;
    l_nb number := 0.999999;
    l_nc number := 0.5;
  begin
    l_t0 := dbms_utility.get_cpu_time;
    if p_number then
      for k in 1 .. c_loops loop
        l_na := l_na * l_nb + l_nc;
      end loop;
      g_sink_d := l_na;
    else
      for k in 1 .. c_loops loop
        l_a := l_a * l_b + l_c;
      end loop;
      g_sink_d := l_a;
    end if;
    return ns_each(dbms_utility.get_cpu_time - l_t0);
  end b2;

  procedure fill(p_kind in varchar2) is
  begin
    case p_kind
      when 'AA' then
        g_aa.delete;
        for i in 1 .. c_cells loop
          g_aa(i) := mod(i, 16);
        end loop;
      when 'NT' then
        g_nt := t_nt();
        g_nt.extend(c_cells);
        for i in 1 .. c_cells loop
          g_nt(i) := mod(i, 16);
        end loop;
      when 'VA' then
        g_va := t_va();
        g_va.extend(c_cells);
        for i in 1 .. c_cells loop
          g_va(i) := mod(i, 16);
        end loop;
    end case;
  end fill;

  procedure b3_fill is
  begin
    fill('AA');
    fill('NT');
    fill('VA');
  end b3_fill;

  -- The read's cost alone: the loop with reads, less the same index walk without them.
  function b3(p_kind in varchar2) return number is
    l_x    simple_integer := 1;
    l_i    simple_integer := 0;
    l_v    simple_integer := 0;
    l_sum  simple_integer := 0;
    l_t0   number;
    l_walk number;
  begin
    l_t0 := dbms_utility.get_cpu_time;
    for k in 1 .. c_loops loop
      l_x := l_x * c_mul + c_add;
      l_i := bitand(l_x, c_mask) + 1;
      l_sum := l_sum + l_i;
    end loop;
    l_walk := dbms_utility.get_cpu_time - l_t0;

    l_t0 := dbms_utility.get_cpu_time;
    case p_kind
      when 'AA' then
        for k in 1 .. c_loops loop
          l_x := l_x * c_mul + c_add;
          l_i := bitand(l_x, c_mask) + 1;
          l_v := g_aa(l_i);
          l_sum := l_sum + l_v;
        end loop;
      when 'NT' then
        for k in 1 .. c_loops loop
          l_x := l_x * c_mul + c_add;
          l_i := bitand(l_x, c_mask) + 1;
          l_v := g_nt(l_i);
          l_sum := l_sum + l_v;
        end loop;
      when 'VA' then
        for k in 1 .. c_loops loop
          l_x := l_x * c_mul + c_add;
          l_i := bitand(l_x, c_mask) + 1;
          l_v := g_va(l_i);
          l_sum := l_sum + l_v;
        end loop;
    end case;
    g_sink := l_sum;
    return ns_each(greatest(0, dbms_utility.get_cpu_time - l_t0 - l_walk));
  end b3;

  function b3_memory(p_kind in varchar2) return number is
    l_before number := pga();
  begin
    fill(p_kind);
    return pga() - l_before;
  end b3_memory;

  function b4(p_columns in pls_integer, p_steps in pls_integer) return number is
    c_focal constant binary_double := 320d;
    c_horizon constant binary_double := 180d;
    c_eye_x constant binary_double := 64.5d;
    c_eye_y constant binary_double := 25.62d;
    c_eye_z constant binary_double := 64.5d;
    l_start timestamp(6) with time zone;
    l_cam   binary_double;
    l_dz    binary_double;
    l_each_x binary_double;
    l_each_z binary_double;
    l_side_x binary_double;
    l_side_z binary_double;
    l_t      binary_double;
    l_b      binary_double;
    l_sum    binary_double := 0;
    l_mx     simple_integer := 0;
    l_mz     simple_integer := 0;
    l_step_z simple_integer := 0;
    l_m      simple_integer := 0;
  begin
    if g_cells.count = 0 then
      $if $$b4_kind = 2 or $$b4_kind = 3 $then
      g_cells.extend(c_cells);
      $end
      for i in 1 .. c_cells loop
        g_cells(i) := mod(i, 16);
      end loop;
    end if;

    l_start := systimestamp;
    for c in 0 .. p_columns - 1 loop
      -- Facing east: F = (1, 0), R = (0, 1), P = 1, so d = (1, cam) (Section 7.2).
      l_cam := 2 * (c + 0.5d) / p_columns - 1;
      l_dz := l_cam;
      l_mx := 64;
      l_mz := 64;
      l_each_x := 1d;
      l_each_z := case when l_dz = 0 then c_never else abs(1 / l_dz) end;
      l_step_z := case when l_dz > 0 then 1 else -1 end;
      l_side_x := (l_mx + 1 - c_eye_x) * l_each_x;
      l_side_z := (case when l_dz > 0 then l_mz + 1 - c_eye_z else c_eye_z - l_mz end) * l_each_z;
      for k in 1 .. p_steps loop
        if l_side_x < l_side_z then
          l_t := l_side_x;
          l_side_x := l_side_x + l_each_x;
          l_mx := l_mx + 1;
        else
          l_t := l_side_z;
          l_side_z := l_side_z + l_each_z;
          l_mz := l_mz + l_step_z;
        end if;
        l_b := c_focal / l_t;
        l_m := g_cells(bitand(l_mx, 127) * 8192 + bitand(l_mz, 127) * 64 + 24);       -- one read
        l_sum := l_sum + (c_horizon - (l_m - c_eye_y) * l_b) + (c_horizon - (23d - c_eye_y) * l_b); -- two projections
      end loop;
    end loop;
    g_sink_d := l_sum;
    return ms_since(l_start);
  end b4;

  function b5(p_part in varchar2, p_columns in pls_integer) return number is
    l_header pc_frame.t_header;
    l_frame  blob;
    l_start  timestamp(6) with time zone;
    l_record number;
  begin
    pc_frame.init(p_columns, 360);
    pc_frame.begin_frame;
    l_start := systimestamp;
    for c in 0 .. p_columns - 1 loop
      for k in 0 .. 22 loop
        pc_frame.run(k * 15, 15, mod(c + k, 256));
      end loop;
      pc_frame.run(345, 15, mod(c + 23, 256)); -- unlike its neighbour, so no runs merge
      pc_frame.end_column;
    end loop;
    l_record := ms_since(l_start);
    l_start := systimestamp;
    pc_frame.finish(l_header, l_frame);
    return case p_part when 'record' then l_record else ms_since(l_start) end;
  end b5;

  procedure b6(p_frame out blob) is
  begin
    if g_b6 is null then
      dbms_lob.createtemporary(g_b6, cache => true, dur => dbms_lob.session);
      for i in 1 .. 5 loop
        dbms_lob.writeappend(g_b6, 15000, utl_raw.copies(hextoraw('00'), 15000));
      end loop;
    end if;
    p_frame := g_b6;
  end b6;

end pc_bench;
/
