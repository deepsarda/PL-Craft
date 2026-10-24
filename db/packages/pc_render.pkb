create or replace package body pc_render as

  -- STUB until Sections 7 and 8 are built: no DDA walk and no spans. It finds the surface under the eye and
  -- paints the same column everywhere, that surface stretched flat to the horizon and fogged by distance,
  -- under the sky bands of Section 8.7. Enough to see walking, jumping and falling. Heat maps are not
  -- painted. Tests T-R1 to T-R5 (Section 15) define done.

  type t_ints is table of pls_integer index by pls_integer;

  g_width     pls_integer;
  g_height    pls_integer;
  g_focal     binary_double;
  g_far       binary_double;
  g_fog_start binary_double;
  g_fog_step  binary_double;

  procedure init(p_debug_heatmap in boolean default false) is
  begin
    g_width := pc_const.setting('SCREEN_W');
    g_height := pc_const.setting('SCREEN_H');
    g_focal := g_width / 2 / tan(pc_const.setting('FOV_H_DEG') * acos(-1) / 360);
    g_far := pc_const.setting('FAR');
    g_fog_start := pc_const.setting('FOG_START');
    g_fog_step := (g_far - g_fog_start) / 3;
  end init;

  function heatmap return boolean is
  begin
    return false;
  end heatmap;

  -- Fog band 0–3 from depth (Section 8.7).
  function band(p_t in binary_double) return pls_integer is
  begin
    return greatest(0, least(3, floor((p_t - g_fog_start) / g_fog_step) + 1));
  end band;

  procedure render(
    p_eye_x in binary_double,
    p_eye_y in binary_double,
    p_eye_z in binary_double,
    p_yaw   in binary_double,
    p_pitch in binary_double)
  is
    l_horizon binary_double := g_height / 2 + g_focal * tan(p_pitch); -- Section 7.3
    l_surface pls_integer;  -- height of the surface under the eye; null when there is none
    l_m       pls_integer;
    l_row     binary_double;
    l_depth   binary_double;
    l_index   t_ints;       -- palette index for each row of the column
    l_start   t_ints;       -- that column as runs
    l_length  t_ints;
    l_runs    pls_integer := 0;
  begin
    for y in reverse 0 .. least(pc_const.c_world_y - 1, floor(p_eye_y)) loop
      l_m := pc_world.get_block(floor(p_eye_x), y, floor(p_eye_z));
      if l_m != pc_const.c_air then
        l_surface := y + 1;
        exit;
      end if;
    end loop;

    for r in 0 .. g_height - 1 loop
      l_row := r + 0.5d;
      l_depth := case when l_surface is not null and l_row > l_horizon
                      then g_focal * (p_eye_y - l_surface) / (l_row - l_horizon) end;
      if l_depth <= g_far then
        l_index(r) := l_m * 16 + 4 * band(l_depth); -- the surface material's top face
      else
        l_index(r) := case when l_row < l_horizon - 120 then 0
                           when l_row < l_horizon - 60 then 1
                           when l_row < l_horizon - 20 then 2
                           else 3 end;
      end if;
      if r = 0 or l_index(r) != l_index(r - 1) then
        l_runs := l_runs + 1;
        l_start(l_runs) := r;
        l_length(l_runs) := 0;
      end if;
      l_length(l_runs) := l_length(l_runs) + 1;
    end loop;

    for c in 1 .. g_width loop
      for k in 1 .. l_runs loop
        pc_frame.run(l_start(k), l_length(k), l_index(l_start(k)));
      end loop;
      pc_frame.end_column;
    end loop;
  end render;

end pc_render;
/
