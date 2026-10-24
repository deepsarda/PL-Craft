-- Frame packing tests (Sections 9 and 15). Same conventions as physics.sql.

-- T-F2: a frame packed in PL/SQL has the header bytes the browser's decoder expects, and the Section 9.1 column
declare
  -- The same bytes client/client.test.js checks the JS header writer against. Bytes 20–21 (pack_us) are
  -- measured, so they are skipped.
  c_before_pack constant varchar2(40) := '504301010000072A028001680000474A01360000';
  c_after_pack  constant varchar2(60) := '00000000FBF400005DC00000FBF43D5C7830020300420017004100000780';
  c_column      constant varchar2(34) := '0003' || '000000B400' || '00B4002845' || '00DC008C42';
  l_header pc_frame.t_header;
  l_frame  blob;
  l_hex    varchar2(104);
begin
  pc_frame.init(640, 360);
  pc_frame.begin_frame;
  for c in 1 .. 640 loop
    pc_frame.run(0, 180, 0);
    pc_frame.run(180, 40, 69);
    pc_frame.run(220, 140, 66);
    pc_frame.end_column;
  end loop;
  l_header.flags := 1;
  l_header.seq := 1834;
  l_header.render_us := 18250;
  l_header.phys_us := 310;
  l_header.px := 64.5;
  l_header.py := 24;
  l_header.pz := 64.5;
  l_header.yaw := 1.5708;
  l_header.pitch := -0.2;
  l_header.held := 2;
  l_header.target_face := 3;
  l_header.target_x := 66;
  l_header.target_y := 23;
  l_header.target_z := 65;
  pc_frame.finish(l_header, l_frame);

  l_hex := rawtohex(dbms_lob.substr(l_frame, 52, 1));
  if substr(l_hex, 1, 40) != c_before_pack or substr(l_hex, 45) != c_after_pack then
    raise_application_error(-20000, 'header is ' || l_hex);
  end if;
  if rawtohex(dbms_lob.substr(l_frame, 17, 53)) != c_column
     or rawtohex(dbms_lob.substr(l_frame, 17, 53 + 639 * 17)) != c_column then
    raise_application_error(-20000, 'the first or last column is not the Section 9.1 example');
  end if;
  if dbms_lob.getlength(l_frame) != 52 + 640 * 17 then
    raise_application_error(-20000, 'frame is ' || dbms_lob.getlength(l_frame) || ' bytes, expected ' || (52 + 640 * 17));
  end if;
end;
/

-- 9.2: a frame of 16,000 runs, which takes several 32,000-character flushes, keeps every byte in order
declare
  l_header pc_frame.t_header;
  l_frame  blob;
  l_at     pls_integer := 53;
begin
  pc_frame.init(640, 360);
  pc_frame.begin_frame;
  for c in 0 .. 639 loop
    for k in 0 .. 23 loop
      pc_frame.run(k * 14, 14, mod(c + k, 256));
    end loop;
    pc_frame.run(336, 24, mod(c + 24, 256)); -- a colour unlike its neighbour, so it stays its own run
    pc_frame.end_column;
  end loop;
  pc_frame.finish(l_header, l_frame);

  if dbms_lob.getlength(l_frame) != 52 + 640 * (2 + 25 * 5) then
    raise_application_error(-20000, 'frame is ' || dbms_lob.getlength(l_frame) || ' bytes');
  end if;
  if rawtohex(dbms_lob.substr(l_frame, 4, 49)) != '00003E80' then
    raise_application_error(-20000, 'run_total is ' || rawtohex(dbms_lob.substr(l_frame, 4, 49)) || ', expected 16000');
  end if;
  for c in 0 .. 639 loop
    if rawtohex(dbms_lob.substr(l_frame, 2, l_at)) != '0019'
       or rawtohex(dbms_lob.substr(l_frame, 1, l_at + 2 + 2 * 5 + 4)) != pc_const.g_hex(mod(c + 2, 256)) then
      raise_application_error(-20000, 'column ' || c || ' is out of place at byte ' || l_at);
    end if;
    l_at := l_at + 2 + 25 * 5;
  end loop;
end;
/

-- A run continuing the column's last run in the same colour joins it, painting downward or upward
declare
  l_header pc_frame.t_header;
  l_frame  blob;
begin
  pc_frame.init(1, 360);
  pc_frame.begin_frame;
  pc_frame.run(300, 60, 64); -- near grass
  pc_frame.run(280, 20, 64); -- the next cell's grass, just above: joins, now rows 280–359
  pc_frame.run(270, 10, 68); -- fogged: a new run
  pc_frame.run(0, 100, 0);   -- sky, not touching: a new run
  pc_frame.run(100, 170, 0); -- sky just below it: joins, now rows 0–269
  pc_frame.end_column;
  pc_frame.finish(l_header, l_frame);
  if rawtohex(dbms_lob.substr(l_frame, 17, 53)) != '0003' || '0118005040' || '010E000A44' || '0000010E00' then
    raise_application_error(-20000, 'runs are ' || rawtohex(dbms_lob.substr(l_frame, 17, 53)));
  end if;
end;
/
