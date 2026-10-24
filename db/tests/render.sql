-- Span cache and renderer tests (Sections 5.4, 8 and 15). Same conventions as physics.sql. T-R3, the golden
-- frames on seed 1337, waits for real terrain (pc_noise).

-- T-W2: spans for a plains column, the same column with an arch over it, and 64 stripes that overflow
declare
  function spans(p_x in pls_integer, p_z in pls_integer) return varchar2 is
    l_col  pls_integer := p_x * 128 + p_z;
    l_list varchar2(4000);
  begin
    for k in 0 .. pc_world.g_span_n(l_col + 1) - 1 loop
      l_list := l_list || ' [' || pc_world.g_span_y0(l_col * 16 + k + 1) || ',' || pc_world.g_span_y1(l_col * 16 + k + 1)
             || ')' || pc_world.g_span_m(l_col * 16 + k + 1);
    end loop;
    return ltrim(l_list);
  end spans;
begin
  pc_world.clear(0);
  pc_world.set_block(10, 0, 40, pc_const.c_bedrock); -- the plains column of Section 5.4
  for y in 1 .. 19 loop
    pc_world.set_block(10, y, 40, pc_const.c_stone);
  end loop;
  for y in 20 .. 22 loop
    pc_world.set_block(10, y, 40, pc_const.c_dirt);
  end loop;
  pc_world.set_block(10, 23, 40, pc_const.c_grass);
  if spans(10, 40) != '[0,1)1 [1,20)2 [20,23)3 [23,24)4' then
    raise_application_error(-20000, 'plains spans are ' || spans(10, 40));
  end if;

  for y in 30 .. 32 loop -- an arch of stone above it: one more span, and that is all an arch is
    pc_world.set_block(10, y, 40, pc_const.c_stone);
  end loop;
  if spans(10, 40) != '[0,1)1 [1,20)2 [20,23)3 [23,24)4 [30,33)2' then
    raise_application_error(-20000, 'arch spans are ' || spans(10, 40));
  end if;

  for y in 0 .. 63 loop -- stone and dirt stripes: a 17th span would open at y = 16, so the 16th runs to the top
    pc_world.set_block(11, y, 40, case when mod(y, 2) = 0 then pc_const.c_stone else pc_const.c_dirt end);
  end loop;
  if pc_world.g_span_n(11 * 128 + 40 + 1) != 16 or spans(11, 40) not like '% [14,15)2 [15,64)3' then
    raise_application_error(-20000, 'striped column spans are ' || spans(11, 40));
  end if;
end;
/

-- T-R2: the coverage list, fed the arch example of Section 8.5, paints exactly the rows that table shows
declare
  l_header pc_frame.t_header;
  l_frame  blob;
begin
  pc_frame.init(1, 360);
  pc_frame.begin_frame;
  pc_render.reset_coverage(360);
  pc_render.fill(300, 359, 10); -- near ground top
  pc_render.fill(240, 310, 11); -- hill wall: rows 300–310 are taken
  pc_render.fill(100, 130, 12); -- arch underside
  pc_render.fill(180, 250, 13); -- far hill wall
  pc_render.fill(0, 359, 14);   -- sky: only rows 0–99 and 131–179 are left
  pc_render.end_column;
  pc_frame.finish(l_header, l_frame);
  if rawtohex(dbms_lob.substr(l_frame, 32, 53)) != '0006' || '012C003C0A' || '00F0003C0B' || '0064001F0C'
                                                  || '00B4003C0D' || '000000640E' || '00830031' || '0E' then
    raise_application_error(-20000, 'runs are ' || rawtohex(dbms_lob.substr(l_frame, 32, 53)));
  end if;
end;
/

-- T-R4: no fisheye; a flat wall at one perpendicular depth has its top on the same row in every column
declare
  l_header pc_frame.t_header;
  l_frame  blob;
  l_at     pls_integer := 53;
  l_runs   pls_integer;
  l_top    pls_integer;
  l_index  pls_integer;
begin
  pc_world.clear(0);
  for z in 0 .. 127 loop -- a stone wall facing the eye, its near face at x = 75, its top at y = 31
    for y in 0 .. 30 loop
      pc_world.set_block(75, y, z, pc_const.c_stone);
    end loop;
  end loop;
  pc_render.init;
  pc_frame.init(640, 360);
  pc_frame.begin_frame;
  pc_render.render(64.5, 25.62, 64.5, 0, 0); -- facing east, 10.5 from the wall
  pc_frame.finish(l_header, l_frame);
  for c in 0 .. 639 loop
    l_runs := to_number(rawtohex(dbms_lob.substr(l_frame, 2, l_at)), 'XXXX');
    l_at := l_at + 2;
    l_top := null;
    for k in 1 .. l_runs loop
      l_index := to_number(rawtohex(dbms_lob.substr(l_frame, 1, l_at + 4)), 'XX');
      if l_index = 2 * 16 + 1 then -- stone, x-facing wall, no fog
        l_top := to_number(rawtohex(dbms_lob.substr(l_frame, 2, l_at)), 'XXXX');
      end if;
      l_at := l_at + 5;
    end loop;
    -- row = 180 − 320 × (31 − 25.62) / 10.5 = 16.04, so row 16 everywhere
    if l_top is null or l_top != 16 then
      raise_application_error(-20000, 'column ' || c || ' has the wall''s top at row ' || nvl(to_char(l_top), 'none'));
    end if;
  end loop;
end;
/

-- T-R1 and T-R5: on 100 random poses every row is painted exactly once, and the early-outs change nothing
declare
  l_header pc_frame.t_header;
  l_frame  blob;
  l_first  blob;
  l_seed   number := 1337;
  l_error  varchar2(200);
  l_x      binary_double;
  l_y      binary_double;
  l_z      binary_double;
  l_yaw    binary_double;
  l_pitch  binary_double;
  l_bx     pls_integer;
  l_by     pls_integer;
  l_bz     pls_integer;
  c_kinds  constant varchar2(30) := '2 3 4 5 7 8 9 10 11 12'; -- every placeable material

  function rand return number is -- Park–Miller, as Section 6.1 uses: the same scenes and poses every run
  begin
    l_seed := mod(l_seed * 16807, 2147483647);
    return l_seed / 2147483647;
  end rand;

  function pick(p_from in pls_integer, p_to in pls_integer) return pls_integer is
  begin
    return p_from + floor(rand * (p_to - p_from + 1));
  end pick;

  procedure frame(p_early_outs in boolean) is
  begin
    pc_render.g_early_outs := p_early_outs;
    pc_frame.begin_frame;
    pc_render.render(l_x, l_y, l_z, l_yaw, l_pitch);
    pc_frame.finish(l_header, l_frame);
  end frame;
begin
  -- A cluttered world: pillars of mixed materials, floating slabs for undersides and arches, pits for walls
  -- below the eye.
  pc_world.clear(24);
  for i in 1 .. 300 loop
    l_bx := pick(2, 125);
    l_bz := pick(2, 125);
    l_by := pick(1, 8);
    l_error := regexp_substr(c_kinds, '[0-9]+', 1, pick(1, 10));
    for y in 24 .. 23 + l_by loop
      pc_world.set_block(l_bx, y, l_bz, to_number(l_error));
    end loop;
  end loop;
  for i in 1 .. 60 loop
    l_bx := pick(2, 123);
    l_bz := pick(2, 123);
    l_by := pick(27, 33);
    for dx in 0 .. 2 loop
      for dz in 0 .. 2 loop
        pc_world.set_block(l_bx + dx, l_by, l_bz + dz, pc_const.c_leaves);
      end loop;
    end loop;
  end loop;
  for i in 1 .. 80 loop
    l_bx := pick(2, 125);
    l_bz := pick(2, 125);
    pc_world.set_block(l_bx, 23, l_bz, pc_const.c_air);
    pc_world.set_block(l_bx, 22, l_bz, pc_const.c_air);
  end loop;

  pc_render.init;
  pc_frame.init(640, 360);
  dbms_lob.createtemporary(l_first, true);
  for p in 1 .. 100 loop
    l_x := 10 + rand * 108;
    l_y := 24 + rand * 12 + pc_const.c_eye_height;
    l_z := 10 + rand * 108;
    l_yaw := rand * 2 * acos(-1);
    l_pitch := (rand * 2 - 1) * 35 * acos(-1) / 180;

    frame(true);
    l_error := pc_frame.coverage_error;
    if l_error is not null then
      raise_application_error(-20000, 'pose ' || p || ': ' || l_error);
    end if;
    dbms_lob.trim(l_first, 0);
    dbms_lob.copy(l_first, l_frame, dbms_lob.getlength(l_frame));

    frame(false);
    if dbms_lob.getlength(l_first) != dbms_lob.getlength(l_frame)
       or dbms_lob.compare(l_first, l_frame, dbms_lob.getlength(l_frame) - 52, 53, 53) != 0 then
      raise_application_error(-20000, 'pose ' || p || ': the early-outs changed the frame');
    end if;
  end loop;
  pc_render.g_early_outs := true;
  dbms_lob.freetemporary(l_first);
end;
/
