-- Terrain generation tests (Sections 6 and 15). Same conventions as physics.sql. A world's span cache describes
-- every block that is not air, so a checksum over it stands for the whole world.

-- 6.5: the worked phase 1 columns, H = 28 inland and H = 19 on a beach
declare
  c_inland constant varchar2(128) := '01' || rpad('02', 46, '02') || '030303' || '04' || rpad('00', 72, '00');
  c_beach  constant varchar2(128) := '01' || rpad('02', 28, '02') || '05050505' || '06' || rpad('00', 88, '00');
begin
  if pc_world.column_hex(28) != c_inland then -- bedrock, stone 1–23, dirt 24–26, grass 27
    raise_application_error(-20000, 'H = 28 gives ' || pc_world.column_hex(28));
  end if;
  if pc_world.column_hex(19) != c_beach then -- bedrock, stone 1–14, sand 15–18, water 19
    raise_application_error(-20000, 'H = 19 gives ' || pc_world.column_hex(19));
  end if;
end;
/

-- G1 and T-W3: a seed always gives the same world, and a saved world loads back block for block
declare
  c_world constant pls_integer := 999999; -- removed again at the end
  l_first  number;
  l_other  number;
  l_saved  number;
  l_loaded number;

  function checksum return number is
    l_sum  number := 0;
    l_slot pls_integer;
  begin
    for col in 0 .. 128 * 128 - 1 loop
      l_sum := mod(l_sum * 31 + pc_world.g_span_n(col + 1), 2147483647);
      for k in 0 .. pc_world.g_span_n(col + 1) - 1 loop
        l_slot := col * 16 + k + 1;
        l_sum := mod(l_sum * 31 + pc_world.g_span_y0(l_slot) * 4096 + pc_world.g_span_y1(l_slot) * 64
                     + pc_world.g_span_m(l_slot), 2147483647);
      end loop;
    end loop;
    return l_sum;
  end checksum;
begin
  pc_world.build(1337, 1);
  l_first := checksum;
  pc_world.build(99, 1);
  l_other := checksum;
  pc_world.generate(c_world, 1337, 1); -- the same seed again, this time saved (and committed)
  l_saved := checksum;
  pc_world.clear(0);
  pc_world.load(c_world);
  l_loaded := checksum;
  delete from pc_column where world_id = c_world;
  delete from pc_worlds where world_id = c_world;
  commit;
  if l_other = l_first then
    raise_application_error(-20000, 'seeds 1337 and 99 gave the same world');
  end if;
  if l_saved != l_first then
    raise_application_error(-20000, 'seed 1337 gave a different world the second time');
  end if;
  if l_loaded != l_saved then
    raise_application_error(-20000, 'the world loaded back differs from the one saved');
  end if;
end;
/

-- G2 and 6.6: phase 2 carves overhangs and arches, and every column keeps its bedrock
declare
  l_slot      pls_integer;
  l_overhangs pls_integer := 0;
begin
  pc_world.build(1337, 2);
  for col in 0 .. 128 * 128 - 1 loop
    l_slot := col * 16 + 1;
    if pc_world.g_span_y0(l_slot) != 0 or pc_world.g_span_m(l_slot) != pc_const.c_bedrock then
      raise_application_error(-20000, 'column ' || col || ' does not start with bedrock');
    end if;
    for k in 1 .. pc_world.g_span_n(col + 1) - 1 loop
      if pc_world.g_span_y0(l_slot + k) > pc_world.g_span_y1(l_slot + k - 1) then -- air below a solid span
        l_overhangs := l_overhangs + 1;
        exit;
      end if;
    end loop;
  end loop;
  if l_overhangs = 0 then
    raise_application_error(-20000, 'phase 2 made no overhangs or arches');
  end if;
end;
/
