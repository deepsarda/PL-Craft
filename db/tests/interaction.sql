-- Block interaction tests (Sections 11 and 15). Same conventions as physics.sql.

-- T-I1: the Section 11.1 example hits block (67, 23, 64) through its top, with (67, 24, 64) in front of it
declare
  l_hit pc_phys.t_hit;
begin
  pc_world.clear(24);
  pc_phys.init;
  pc_phys.place(64.5, 24, 64.5, p_yaw => 0, p_pitch => -acos(-1) / 6); -- eye at 25.62, facing east, 30° down
  l_hit := pc_phys.raycast;
  if not l_hit.hit or l_hit.x != 67 or l_hit.y != 23 or l_hit.z != 64 or l_hit.face != 3
     or l_hit.prev_x != 67 or l_hit.prev_y != 24 or l_hit.prev_z != 64 then
    raise_application_error(-20000, 'hit (' || l_hit.x || ', ' || l_hit.y || ', ' || l_hit.z || ') face ' || l_hit.face
      || ', in front (' || l_hit.prev_x || ', ' || l_hit.prev_y || ', ' || l_hit.prev_z || ')');
  end if;
end;
/

-- T-I2: placing a block where it would overlap the player is refused
declare
  l_hit pc_phys.t_hit;
begin
  pc_world.clear(24);
  pc_world.set_block(65, 24, 64, pc_const.c_stone);
  pc_world.set_block(65, 25, 64, pc_const.c_stone);
  pc_phys.init;
  pc_phys.place(64.5, 24.001, 64.5); -- facing east, a two-high wall right in front
  l_hit := pc_phys.raycast;
  if not l_hit.hit or l_hit.prev_x != 64 or l_hit.prev_y != 25 then
    raise_application_error(-20000, 'the test aims wrong: the cell in front of the target should be the player''s own');
  end if;
  if pc_phys.place_block(pc_const.c_planks) or pc_world.get_block(64, 25, 64) != pc_const.c_air then
    raise_application_error(-20000, 'placed a block inside the player');
  end if;
end;
/

-- T-I3: bedrock cannot be broken
declare
  l_hit pc_phys.t_hit;
begin
  pc_world.clear(1); -- just the bedrock layer
  pc_phys.init;
  pc_phys.place(64.5, 1.001, 64.5, p_pitch => -acos(-1) / 6);
  l_hit := pc_phys.raycast;
  if not l_hit.hit or pc_world.get_block(l_hit.x, l_hit.y, l_hit.z) != pc_const.c_bedrock then
    raise_application_error(-20000, 'the test aims wrong: not looking at bedrock');
  end if;
  if pc_phys.break_block or pc_world.get_block(l_hit.x, l_hit.y, l_hit.z) != pc_const.c_bedrock then
    raise_application_error(-20000, 'broke bedrock');
  end if;
end;
/

-- 11.2 and 11.3: placing puts the held block in front of the target, and breaking removes what is targeted
begin
  pc_world.clear(24);
  pc_phys.init;
  pc_phys.place(64.5, 24, 64.5, p_pitch => -acos(-1) / 6); -- aiming at the top of (67, 23, 64)
  if not pc_phys.place_block(pc_const.c_planks) or pc_world.get_block(67, 24, 64) != pc_const.c_planks then
    raise_application_error(-20000, 'did not place planks at (67, 24, 64)');
  end if;
  if not pc_phys.break_block or pc_world.get_block(67, 24, 64) != pc_const.c_air then
    raise_application_error(-20000, 'did not break the planks at (67, 24, 64)');
  end if;
  if pc_phys.place_block(pc_const.c_water) then
    raise_application_error(-20000, 'placed water, which is not placeable');
  end if;
end;
/
