-- Physics tests (Sections 10 and 15). Run with npm run db:test: each block is one test, named by its first
-- comment line, failing by raising an error and rolled back afterwards. They use worlds made by
-- pc_world.clear, which live only in memory, and assume the Section 14 defaults in PC_CONFIG.

-- 10.2: mouse look turns MOUSE_SENS radians per pixel, wraps yaw into 0 to 2π, and stops pitch at the limit
declare
  c_pi constant binary_double := acos(-1d);
begin
  pc_phys.init;
  pc_phys.place(64.5, 24, 64.5);
  pc_phys.look(400, 0);
  if abs(pc_phys.g_player.yaw - 1) > 1e-9 then
    raise_application_error(-20000, '400 px turned to yaw ' || to_char(pc_phys.g_player.yaw, 'fm990.000000') || ', expected 1');
  end if;
  pc_phys.look(-800, 0);
  if abs(pc_phys.g_player.yaw - (2 * c_pi - 1)) > 1e-9 then
    raise_application_error(-20000, 'yaw did not wrap: ' || to_char(pc_phys.g_player.yaw, 'fm990.000000'));
  end if;
  pc_phys.look(0, -100000);
  if abs(pc_phys.g_player.pitch - pc_const.setting('PITCH_LIMIT_DEG') * c_pi / 180) > 1e-9 then
    raise_application_error(-20000, 'pitch went to ' || to_char(pc_phys.g_player.pitch, 'fm990.000000')
      || ', limit is ' || pc_const.setting('PITCH_LIMIT_DEG') || '°');
  end if;
end;
/

-- T-P1: dropped from y = 40 onto flat ground, the feet come to rest 0.001 above it, on the ground
begin
  pc_world.clear(24);
  pc_phys.init;
  pc_phys.place(64.5, 40, 64.5);
  for i in 1 .. 96 loop -- 4 s at 24 fps
    pc_phys.step(0, 1 / 24);
    if pc_phys.g_player.py < 24 then
      raise_application_error(-20000, 'fell into the ground: feet at ' || to_char(pc_phys.g_player.py, 'fm9990.000000'));
    end if;
  end loop;
  if abs(pc_phys.g_player.py - 24.001) > 1e-9 or not pc_phys.g_player.on_ground then
    raise_application_error(-20000, 'feet at ' || to_char(pc_phys.g_player.py, 'fm9990.000000')
      || ', expected 24.001 and on the ground');
  end if;
end;
/

-- T-P2: falling at terminal speed onto a one-block slab, the player lands on it instead of passing through
begin
  pc_world.clear(0); -- all air, so the slab is the only thing to hit
  for x in 62 .. 66 loop
    for z in 62 .. 66 loop
      pc_world.set_block(x, 10, z, pc_const.c_stone);
    end loop;
  end loop;
  pc_phys.init;
  pc_phys.place(64.5, 50, 64.5);
  pc_phys.g_player.vy := -40;
  for i in 1 .. 48 loop
    pc_phys.step(0, 1 / 24);
  end loop;
  if abs(pc_phys.g_player.py - 11.001) > 1e-9 then
    raise_application_error(-20000, 'feet at ' || to_char(pc_phys.g_player.py, 'fm9990.000000') || ', expected 11.001 on the slab');
  end if;
end;
/

-- T-P3: walking diagonally into a wall, the player stops at it and keeps sliding along it
begin
  pc_world.clear(24);
  for z in 40 .. 90 loop
    for y in 24 .. 26 loop
      pc_world.set_block(66, y, z, pc_const.c_stone);
    end loop;
  end loop;
  pc_phys.init;
  pc_phys.place(65, 24.001, 64.5, p_yaw => acos(-1) / 4); -- facing south-east, into the wall at x = 66
  for i in 1 .. 24 loop
    pc_phys.step(1, 1 / 24); -- W for 1 s
  end loop;
  if pc_phys.g_player.px > 66 - 0.3 then
    raise_application_error(-20000, 'went into the wall: x = ' || to_char(pc_phys.g_player.px, 'fm9990.000000'));
  end if;
  if pc_phys.g_player.pz < 66 then
    raise_application_error(-20000, 'stuck on the wall instead of sliding: z = ' || to_char(pc_phys.g_player.pz, 'fm9990.000000'));
  end if;
end;
/

-- T-P4: with default settings a running jump clears a one-block step but not a two-block one
begin
  pc_world.clear(24);
  for x in 66 .. 70 loop
    for z in 40 .. 90 loop
      pc_world.set_block(x, 24, z, pc_const.c_stone);
    end loop;
  end loop;
  pc_phys.init;
  pc_phys.place(65, 24.001, 64.5); -- facing east
  for i in 1 .. 36 loop
    pc_phys.step(1 + 16, 1 / 24); -- W and Space for 1.5 s
  end loop;
  if pc_phys.g_player.px < 66.5 or pc_phys.g_player.py < 25 then
    raise_application_error(-20000, 'did not get onto the one-block step: x = ' || to_char(pc_phys.g_player.px, 'fm9990.000')
      || ', y = ' || to_char(pc_phys.g_player.py, 'fm9990.000'));
  end if;

  pc_world.clear(24);
  for x in 66 .. 70 loop
    for z in 40 .. 90 loop
      pc_world.set_block(x, 24, z, pc_const.c_stone);
      pc_world.set_block(x, 25, z, pc_const.c_stone);
    end loop;
  end loop;
  pc_phys.place(65, 24.001, 64.5);
  for i in 1 .. 36 loop
    pc_phys.step(1 + 16, 1 / 24);
  end loop;
  if pc_phys.g_player.px > 66 then
    raise_application_error(-20000, 'climbed a two-block step: x = ' || to_char(pc_phys.g_player.px, 'fm9990.000'));
  end if;
end;
/
