create or replace package body pc_phys as

  c_half  constant binary_double := 0.3d;  -- the box is 0.6 × 1.8 × 0.6 with the feet at its bottom centre
  c_tall  constant binary_double := 1.8d;
  c_eps   constant binary_double := 0.001d; -- keeps the box off faces, so it never sticks to them (10.5)
  c_never constant binary_double := 1e30;   -- step length along an axis the ray never crosses

  type t_vec is varray(3) of binary_double;
  type t_cells is varray(3) of pls_integer;

  -- Settings (Section 14.3), read by init.
  g_sens      binary_double;
  g_pitch_max binary_double;
  g_walk      binary_double;
  g_sprint    binary_double;
  g_sneak     binary_double;
  g_gravity   binary_double;
  g_jump      binary_double; -- take-off speed that reaches JUMP_HEIGHT: √(2 g h)
  g_terminal  binary_double;
  g_max_dt    binary_double;
  g_reach     binary_double;

  procedure init is
  begin
    g_sens := pc_const.setting('MOUSE_SENS');
    g_pitch_max := pc_const.setting('PITCH_LIMIT_DEG') * acos(-1) / 180;
    g_walk := pc_const.setting('WALK_SPEED');
    g_sprint := pc_const.setting('SPRINT_SPEED');
    g_sneak := pc_const.setting('SNEAK_SPEED');
    g_gravity := pc_const.setting('GRAVITY');
    g_jump := sqrt(2 * g_gravity * pc_const.setting('JUMP_HEIGHT'));
    g_terminal := pc_const.setting('TERMINAL_VEL');
    g_max_dt := pc_const.setting('MAX_DT');
    g_reach := pc_const.setting('REACH');
  end init;

  procedure place(
    p_px    in binary_double,
    p_py    in binary_double,
    p_pz    in binary_double,
    p_yaw   in binary_double default 0,
    p_pitch in binary_double default 0)
  is
  begin
    g_player.px := p_px;
    g_player.py := p_py;
    g_player.pz := p_pz;
    g_player.yaw := p_yaw;
    g_player.pitch := p_pitch;
    g_player.vx := 0;
    g_player.vy := 0;
    g_player.vz := 0;
    g_player.on_ground := false;
    g_player.last_tick := systimestamp;
  end place;

  procedure load(p_player_id in pls_integer, p_world_id in pls_integer) is
    l_mid_x   constant pls_integer := pc_const.c_world_x / 2;
    l_mid_z   constant pls_integer := pc_const.c_world_z / 2;
    l_surface pls_integer := 0;
    l_px      binary_double;
    l_py      binary_double;
    l_pz      binary_double;
    l_yaw     binary_double;
    l_pitch   binary_double;
  begin
    for y in reverse 0 .. pc_const.c_world_y - 1 loop
      if pc_world.get_block(l_mid_x, y, l_mid_z) != pc_const.c_air then
        l_surface := y + 1;
        exit;
      end if;
    end loop;

    merge into pc_player p
    using (select p_player_id player_id from dual) s
    on (p.player_id = s.player_id)
    when not matched then
      insert (player_id, world_id, name, px, py, pz, yaw, pitch, held, saved_at)
      values (p_player_id, p_world_id, 'Player ' || p_player_id, l_mid_x + 0.5, l_surface, l_mid_z + 0.5,
              0, 0, pc_const.c_stone, systimestamp);

    select px, py, pz, yaw, pitch, held
      into l_px, l_py, l_pz, l_yaw, l_pitch, g_player.held
      from pc_player
     where player_id = p_player_id;
    g_player.player_id := p_player_id;
    place(l_px, l_py, l_pz, l_yaw, l_pitch);
  end load;

  procedure save is
  begin
    update pc_player
       set px = g_player.px, py = g_player.py, pz = g_player.pz, yaw = g_player.yaw, pitch = g_player.pitch,
           held = g_player.held, saved_at = systimestamp
     where player_id = g_player.player_id;
  end save;

  procedure look(p_mdx in pls_integer, p_mdy in pls_integer) is
    c_tau constant binary_double := 2 * acos(-1d);
  begin
    g_player.yaw := g_player.yaw + p_mdx * g_sens;
    g_player.yaw := g_player.yaw - c_tau * floor(g_player.yaw / c_tau);
    -- Moving the mouse up gives a negative mdy, and moving it up should look up.
    g_player.pitch := greatest(-g_pitch_max, least(g_pitch_max, g_player.pitch - p_mdy * g_sens));
  end look;

  -- True when the box overlaps a solid block, strictly and with ε as in Section 10.5.
  function inside_solid return boolean is
  begin
    for x in floor(g_player.px - c_half + c_eps) .. ceil(g_player.px + c_half - c_eps) - 1 loop
      for y in floor(g_player.py + c_eps) .. ceil(g_player.py + c_tall - c_eps) - 1 loop
        for z in floor(g_player.pz - c_half + c_eps) .. ceil(g_player.pz + c_half - c_eps) - 1 loop
          if pc_world.is_solid(x, y, z) then
            return true;
          end if;
        end loop;
      end loop;
    end loop;
    return false;
  end inside_solid;

  -- Moves along one axis (1 x, 2 y, 3 z) by p_delta, stopping ε short of the first solid face in the way
  -- (Section 10.5). Returns true when the move was cut short; p_delta is then the shortened move.
  function sweep(p_axis in pls_integer, p_delta in out binary_double) return boolean is
    l_lo   t_vec := t_vec(g_player.px - c_half, g_player.py, g_player.pz - c_half);
    l_hi   t_vec := t_vec(g_player.px + c_half, g_player.py + c_tall, g_player.pz + c_half);
    l_from t_cells := t_cells(0, 0, 0);
    l_to   t_cells := t_cells(0, 0, 0);
    l_cell t_cells;
    l_up   constant boolean := p_delta > 0;
    l_stop binary_double;
    l_cut  boolean := false;
  begin
    if p_delta = 0 then
      return false;
    end if;
    -- On the other two axes, the cells the box overlaps. On this one, the cells ahead the move reaches.
    for a in 1 .. 3 loop
      if a != p_axis then
        l_from(a) := floor(l_lo(a) + c_eps);
        l_to(a) := ceil(l_hi(a) - c_eps) - 1;
      elsif l_up then
        l_from(a) := ceil(l_hi(a) - c_eps);
        l_to(a) := ceil(l_hi(a) + p_delta) - 1;
      else
        l_from(a) := floor(l_lo(a) + p_delta);
        l_to(a) := floor(l_lo(a) + c_eps) - 1;
      end if;
    end loop;
    for x in l_from(1) .. l_to(1) loop
      for y in l_from(2) .. l_to(2) loop
        for z in l_from(3) .. l_to(3) loop
          if pc_world.is_solid(x, y, z) then
            l_cell := t_cells(x, y, z);
            if l_up then
              l_stop := l_cell(p_axis) - l_hi(p_axis) - c_eps;     -- up to the block's near face
              if l_stop < p_delta then
                p_delta := l_stop;
                l_cut := true;
              end if;
            else
              l_stop := l_cell(p_axis) + 1 - l_lo(p_axis) + c_eps; -- down to its far face
              if l_stop > p_delta then
                p_delta := l_stop;
                l_cut := true;
              end if;
            end if;
          end if;
        end loop;
      end loop;
    end loop;
    return l_cut;
  end sweep;

  -- One sub-step of p_s seconds: the velocity the keys ask for (10.4), then collision one axis at a time.
  procedure substep(p_keys in pls_integer, p_s in binary_double) is
    l_fwd    binary_double := sign(bitand(p_keys, 1)) - sign(bitand(p_keys, 2)); -- W − S
    l_right  binary_double := sign(bitand(p_keys, 8)) - sign(bitand(p_keys, 4)); -- D − A
    l_wx     binary_double := cos(g_player.yaw) * l_fwd - sin(g_player.yaw) * l_right;
    l_wz     binary_double := sin(g_player.yaw) * l_fwd + cos(g_player.yaw) * l_right;
    l_len    binary_double := sqrt(l_wx * l_wx + l_wz * l_wz);
    l_speed  binary_double := case when bitand(p_keys, 32) > 0 then g_sneak
                                   when bitand(p_keys, 64) > 0 then g_sprint
                                   else g_walk end;
    l_follow binary_double := least(1, 5 * p_s);
    l_d      binary_double;
  begin
    if l_len > 0 then -- unit length first, so diagonals are not faster
      l_wx := l_wx / l_len * l_speed;
      l_wz := l_wz / l_len * l_speed;
    end if;
    if g_player.on_ground then
      g_player.vx := l_wx;
      g_player.vz := l_wz;
    else -- some control in the air, but no turning on a dime
      g_player.vx := g_player.vx + (l_wx - g_player.vx) * l_follow;
      g_player.vz := g_player.vz + (l_wz - g_player.vz) * l_follow;
    end if;
    if bitand(p_keys, 16) > 0 and g_player.on_ground then
      g_player.vy := g_jump;
    end if;
    g_player.vy := greatest(g_player.vy - g_gravity * p_s, -g_terminal);

    -- y first: landing settles before sliding, so the player does not catch on the block underfoot.
    l_d := g_player.vy * p_s;
    if sweep(2, l_d) then
      g_player.on_ground := g_player.vy < 0;
      g_player.vy := 0;
    else
      g_player.on_ground := false;
    end if;
    g_player.py := g_player.py + l_d;

    l_d := g_player.vx * p_s;
    if sweep(1, l_d) then
      g_player.vx := 0;
    end if;
    g_player.px := g_player.px + l_d;

    l_d := g_player.vz * p_s;
    if sweep(3, l_d) then
      g_player.vz := 0;
    end if;
    g_player.pz := g_player.pz + l_d;
  end substep;

  -- Section 10.6: a box inside a solid block (a bug, or an edit from another tool) moves up one block at a
  -- time, at most three times.
  procedure unstick is
  begin
    for i in 1 .. 3 loop
      exit when not inside_solid;
      g_player.py := g_player.py + 1;
      g_player.vy := 0;
      dbms_output.put_line('pc_phys: player ' || g_player.player_id || ' was inside a block and moved up');
    end loop;
  end unstick;

  procedure step(p_keys in pls_integer, p_dt in binary_double) is
    l_dt binary_double := nvl(p_dt, pc_const.seconds_since(g_player.last_tick));
    l_n  pls_integer;
  begin
    g_player.last_tick := systimestamp;
    l_dt := greatest(0, least(g_max_dt, l_dt)); -- a stall must not launch the player across the map
    unstick;
    if l_dt > 0 then
      -- Sub-steps of at most 1/60 s: at terminal speed that is under one block, so no fall skips a block.
      l_n := ceil(l_dt / pc_const.c_substep - 1e-9);
      for i in 1 .. l_n loop
        substep(p_keys, l_dt / l_n);
      end loop;
    end if;
  end step;

  function raycast return t_hit is
    l_hit  t_hit;
    l_eye  t_vec := t_vec(g_player.px, g_player.py + pc_const.c_eye_height, g_player.pz);
    l_dir  t_vec := t_vec(cos(g_player.yaw) * cos(g_player.pitch),
                          sin(g_player.pitch),
                          sin(g_player.yaw) * cos(g_player.pitch));
    l_cell t_cells := t_cells(0, 0, 0);
    l_prev t_cells;
    l_step t_cells := t_cells(0, 0, 0);
    l_each t_vec := t_vec(0, 0, 0); -- distance per whole cell along each axis
    l_next t_vec := t_vec(0, 0, 0); -- distance at which the ray next crosses a grid line on each axis
    a      pls_integer;
  begin
    for i in 1 .. 3 loop
      l_cell(i) := floor(l_eye(i));
      l_step(i) := case when l_dir(i) > 0 then 1 else -1 end;
      l_each(i) := case when l_dir(i) = 0 then c_never else abs(1 / l_dir(i)) end;
      l_next(i) := (case when l_dir(i) > 0 then l_cell(i) + 1 - l_eye(i) else l_eye(i) - l_cell(i) end) * l_each(i);
    end loop;
    loop
      a := case when l_next(1) <= l_next(2) and l_next(1) <= l_next(3) then 1
                when l_next(2) <= l_next(3) then 2
                else 3 end;
      exit when l_next(a) > g_reach;
      l_prev := l_cell;
      l_cell(a) := l_cell(a) + l_step(a);
      l_next(a) := l_next(a) + l_each(a);
      exit when l_cell(1) not between 0 and pc_const.c_world_x - 1
             or l_cell(2) not between 0 and pc_const.c_world_y - 1
             or l_cell(3) not between 0 and pc_const.c_world_z - 1;
      if pc_world.get_block(l_cell(1), l_cell(2), l_cell(3)) != pc_const.c_air then
        l_hit.hit := true;
        l_hit.x := l_cell(1);
        l_hit.y := l_cell(2);
        l_hit.z := l_cell(3);
        l_hit.prev_x := l_prev(1);
        l_hit.prev_y := l_prev(2);
        l_hit.prev_z := l_prev(3);
        l_hit.face := 2 * (a - 1) + case when l_step(a) > 0 then 0 else 1 end; -- stepping +x enters the −x face
        return l_hit;
      end if;
    end loop;
    return l_hit;
  end raycast;

  -- Whether a block in this cell would overlap the player's box (strict, Section 11.3).
  function overlaps_player(p_x in pls_integer, p_y in pls_integer, p_z in pls_integer) return boolean is
  begin
    return g_player.px - c_half < p_x + 1 and g_player.px + c_half > p_x
       and g_player.py < p_y + 1 and g_player.py + c_tall > p_y
       and g_player.pz - c_half < p_z + 1 and g_player.pz + c_half > p_z;
  end overlaps_player;

  function break_block return boolean is
    l_hit t_hit := raycast;
    l_old pls_integer;
  begin
    if not l_hit.hit then
      return false;
    end if;
    l_old := pc_world.get_block(l_hit.x, l_hit.y, l_hit.z);
    if l_old = pc_const.c_bedrock then
      return false;
    end if;
    pc_world.set_block(l_hit.x, l_hit.y, l_hit.z, pc_const.c_air);
    pc_world.save_edit(l_hit.x, l_hit.y, l_hit.z, l_old, pc_const.c_air, g_player.player_id);
    return true;
  end break_block;

  function place_block(p_held in pls_integer) return boolean is
    l_hit t_hit := raycast;
  begin
    if not l_hit.hit
       or not pc_const.placeable(p_held)
       or l_hit.prev_x not between 0 and pc_const.c_world_x - 1
       or l_hit.prev_y not between 1 and pc_const.c_world_y - 1  -- y = 0 is bedrock's
       or l_hit.prev_z not between 0 and pc_const.c_world_z - 1
       or pc_world.get_block(l_hit.prev_x, l_hit.prev_y, l_hit.prev_z) != pc_const.c_air
       or overlaps_player(l_hit.prev_x, l_hit.prev_y, l_hit.prev_z) -- no burying yourself
    then
      return false;
    end if;
    pc_world.set_block(l_hit.prev_x, l_hit.prev_y, l_hit.prev_z, p_held);
    pc_world.save_edit(l_hit.prev_x, l_hit.prev_y, l_hit.prev_z, pc_const.c_air, p_held, g_player.player_id);
    return true;
  end place_block;

end pc_phys;
/
