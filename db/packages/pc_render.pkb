create or replace package body pc_render as

  c_never constant binary_double := 1e30; -- step length along an axis the ray never crosses

  type t_rows is varray(181) of pls_integer;   -- open intervals: at most 180 in 360 rows, one more mid-split
  type t_cams is varray(640) of binary_double;

  -- Settings and per-screen values, from init.
  g_width     pls_integer;
  g_height    pls_integer;
  g_focal     binary_double;     -- f: pixels per world unit at depth 1 (7.1)
  g_tan_half  binary_double;     -- P = tan(FOV_h / 2)
  g_far       binary_double;
  g_fog_start binary_double;
  g_fog_step  binary_double;
  g_every     pls_integer;       -- EARLYOUT_EVERY
  g_heatmap   boolean := false;
  g_cam       t_cams := t_cams(); -- cam_c of each screen column, at c + 1

  -- The coverage list of the column being draw it open rows as sorted, disjoint intervals.
  g_lo       t_rows := t_rows();
  g_hi       t_rows := t_rows();
  g_open     pls_integer := 0;   -- intervals in use; 0 once the column is full
  g_min_open pls_integer := 0;   -- first and last open row, for quick rejects
  g_max_open pls_integer := -1;
  g_emit     boolean := true;    -- false while drawing a heat map: the walk runs, only its length is shown

  -- The run being built.
  g_run_start  pls_integer := 0;
  g_run_length pls_integer := 0; -- 0 when no run is being built
  g_run_index  pls_integer := 0;

  procedure init(p_debug_heatmap in boolean default false) is
  begin
    g_width := pc_const.setting('SCREEN_W');
    g_height := pc_const.setting('SCREEN_H');
    g_tan_half := tan(pc_const.setting('FOV_H_DEG') * acos(-1) / 360);
    g_focal := g_width / 2 / g_tan_half;
    g_far := pc_const.setting('FAR');
    g_fog_start := pc_const.setting('FOG_START');
    g_fog_step := (g_far - g_fog_start) / 3;
    g_every := greatest(1, pc_const.setting('EARLYOUT_EVERY'));
    g_heatmap := nvl(p_debug_heatmap, false);
    g_cam := t_cams();
    g_cam.extend(g_width);
    for c in 0 .. g_width - 1 loop
      g_cam(c + 1) := 2 * (c + 0.5d) / g_width - 1; -- the +0.5 samples each column at its centre
    end loop;
  end init;

  function heatmap return boolean is
  begin
    return g_heatmap;
  end heatmap;

  procedure emit(p_start in pls_integer, p_length in pls_integer, p_index in pls_integer) is
  begin

    if g_run_length > 0 and p_index = g_run_index then

      if p_start + p_length = g_run_start then
        g_run_start := p_start;
        g_run_length := g_run_length + p_length;
        return;
      elsif g_run_start + g_run_length = p_start then
        g_run_length := g_run_length + p_length;
        return;
      end if;
    end if;

    if g_run_length > 0 then
      pc_frame.run(g_run_start, g_run_length, g_run_index);
    end if;
    
    g_run_start := p_start;
    g_run_length := p_length;
    g_run_index := p_index;
  end emit;

  procedure end_column is
  begin
    if g_run_length > 0 then
      pc_frame.run(g_run_start, g_run_length, g_run_index);
      g_run_length := 0;
    end if;
    pc_frame.end_column;
  end end_column;

  procedure reset_coverage(p_height in pls_integer) is
  begin
    if g_lo.count = 0 then
      g_lo.extend(181);
      g_hi.extend(181);
    end if;
    g_open := 1;
    g_lo(1) := 0;
    g_hi(1) := p_height - 1;
    g_min_open := 0;
    g_max_open := p_height - 1;
  end reset_coverage;

  procedure fill(p_a in pls_integer, p_b in pls_integer, p_index in pls_integer) is
    i      pls_integer := 1;
    l_from pls_integer;
    l_to   pls_integer;
  begin
    if p_a > p_b or p_b < g_min_open or p_a > g_max_open then
      return;
    end if;
    while i <= g_open loop
      if g_hi(i) < p_a then
        i := i + 1;
      elsif g_lo(i) > p_b then
        exit;
      else
        l_from := case when g_lo(i) > p_a then g_lo(i) else p_a end;
        l_to := case when g_hi(i) < p_b then g_hi(i) else p_b end;
        if g_emit then
          emit(l_from, l_to - l_from + 1, p_index);
        end if;

        -- painted the middle, sp the interval splits in two
        if g_lo(i) < p_a and p_b < g_hi(i) then 
          
          for j in reverse i + 1 .. g_open loop
            g_lo(j + 1) := g_lo(j);
            g_hi(j + 1) := g_hi(j);
          end loop;

          g_lo(i + 1) := p_b + 1;
          g_hi(i + 1) := g_hi(i);
          g_hi(i) := p_a - 1;
          g_open := g_open + 1;

          exit;
        -- painted its lower end,  the upper part stays open
        elsif g_lo(i) < p_a then                
          g_hi(i) := p_a - 1;
          i := i + 1;
        -- painted its upper end: the lower part stays open
        elsif p_b < g_hi(i) then                
          g_lo(i) := p_b + 1;
          exit;
        
         -- painted all of it
        else                                   
          for j in i .. g_open - 1 loop
            g_lo(j) := g_lo(j + 1);
            g_hi(j) := g_hi(j + 1);
          end loop;
          g_open := g_open - 1;
        end if;
      end if;
    end loop;
    if g_open > 0 then
      g_min_open := g_lo(1);
      g_max_open := g_hi(g_open);
    else
      g_min_open := g_height;
      g_max_open := -1;
    end if;
  end fill;

  -- The whole row a continuous row edge lands on, we clamp to the screen first, then we round it.
  function edge(p_row in binary_double, p_rows in binary_double) return pls_integer is
  begin
    if p_row <= 0d then
      return 0;
    elsif p_row >= p_rows then
      return p_rows;
    end if;
    return p_row; -- Conversion handles the rounding :)  floor(p_row + 0.5)
  end edge;

  procedure sky(p_a in pls_integer, p_b in pls_integer, p_index in pls_integer) is
  begin
    if p_a <= p_b then
      emit(p_a, p_b - p_a + 1, p_index);
    end if;
  end sky;

  procedure render(
    p_eye_x in binary_double,
    p_eye_y in binary_double,
    p_eye_z in binary_double,
    p_yaw   in binary_double,
    p_pitch in binary_double)
  is
    -- The camera for this frame
    l_height   constant pls_integer := g_height;
    l_rows     constant binary_double := g_height;

    l_focal    constant binary_double := g_focal;

    l_far      constant binary_double := g_far;
    l_near     constant binary_double := pc_const.c_t_near;

    l_ey       constant binary_double := p_eye_y;

    l_fx       constant binary_double := cos(p_yaw);          -- F
    l_fz       constant binary_double := sin(p_yaw);

    l_prx      constant binary_double := -sin(p_yaw) * g_tan_half; -- P · R
    l_prz      constant binary_double := cos(p_yaw) * g_tan_half;

    l_horizon  constant binary_double := g_height / 2 + g_focal * tan(p_pitch); -- h, y-sheared
    l_max_y    constant binary_double := pc_world.max_y;
    
    l_eye_mx   constant pls_integer := floor(p_eye_x);
    l_eye_mz   constant pls_integer := floor(p_eye_z);

    l_prune    constant boolean := g_early_outs;
    l_near_f   constant binary_double := g_focal / pc_const.c_t_near;
    l_far_top  constant binary_double := l_horizon - (l_max_y - l_ey) * l_focal / l_far;
    l_far_bottom constant binary_double := l_horizon + l_ey * l_focal / l_far;

    l_columns  constant pls_integer := pc_const.c_world_z;
    l_slots    constant pls_integer := pc_const.c_max_spans;

    -- The ray and its walk across the grid (8.2). d is not normalised, so every depth is perpendicular.
    l_dx       binary_double;
    l_dz       binary_double;
    l_each_x   binary_double;   -- depth gained per whole cell crossed in x
    l_each_z   binary_double;
    l_side_x   binary_double;   -- depth at which the ray next crosses an x grid line
    l_side_z   binary_double;
    l_step_x   simple_integer := 0;
    l_step_z   simple_integer := 0;
    l_mx       simple_integer := 0;
    l_mz       simple_integer := 0;
    l_t_in     binary_double;   -- the cell's entry and exit depth
    l_t_out    binary_double;
    l_a        binary_double;   -- f / t_in and f / t_out, clamped to the near plane
    l_b        binary_double;
    l_wall     simple_integer := 0;     -- the cell's near wall: 1 x-facing, 2 z-facing, 0 none (the eye's own cell)
    l_walked   simple_integer := 0;
    l_until_check simple_integer := 0; -- cells left before the next early-out (c) check
    l_col_step_x  simple_integer := 0; -- change in the world column index for one step in x
    l_slot_step_x simple_integer := 0; -- and in its first span slot
    l_slot_step_z simple_integer := 0;
    l_fog      binary_double;   -- (t_in − FOG_START) / FOG_STEP

    -- One cell's span.
    l_col      simple_integer := 0;
    l_slot     simple_integer := 0;
    l_n        simple_integer := 0;
    l_kb       simple_integer := 0;
    l_kb_top   simple_integer := 0;     -- the highest span whose bottom is below the eye
    l_band     simple_integer := 0;     -- 4 × fog band, from the cell's entry depth
    l_y        binary_double;
    l_top      simple_integer := 0;
    l_bottom   simple_integer := 0;
    l_reach    boolean;
    l_reach_top    binary_double;  -- rows anything left in the walk could still reach
    l_reach_bottom binary_double;
    l_sky1     pls_integer;
    l_sky2     pls_integer;
    l_sky3     pls_integer;
  begin
    g_emit := not g_heatmap;


    for c in 0 .. g_width - 1 loop
      -- One ray per screen column and the DDA's set-up.
      l_dx := l_fx + g_cam(c + 1) * l_prx;
      l_dz := l_fz + g_cam(c + 1) * l_prz;
      l_mx := l_eye_mx;
      l_mz := l_eye_mz;

      if l_dx > 0 then
        l_step_x := 1;
        l_each_x := 1d / l_dx;
        l_side_x := (l_mx + 1 - p_eye_x) * l_each_x;

      elsif l_dx < 0 then
        l_step_x := -1;
        l_each_x := -1d / l_dx;
        l_side_x := (p_eye_x - l_mx) * l_each_x;
        
      else
        l_step_x := 0;
        l_each_x := c_never;
        l_side_x := c_never;
      end if;

      if l_dz > 0 then
        l_step_z := 1;
        l_each_z := 1d / l_dz;
        l_side_z := (l_mz + 1 - p_eye_z) * l_each_z;
      elsif l_dz < 0 then
        l_step_z := -1;
        l_each_z := -1d / l_dz;
        l_side_z := (p_eye_z - l_mz) * l_each_z;
      else
        l_step_z := 0;
        l_each_z := c_never;
        l_side_z := c_never;
      end if;

      reset_coverage(l_height);
      l_t_in := 0;
      l_a := l_near_f;
      l_wall := 0;
      l_walked := 0;
      l_until_check := g_every;
      l_col := l_mx * l_columns + l_mz; -- then kept up to date by each step
      l_col_step_x := l_step_x * l_columns;
      l_slot := l_col * l_slots + 1;
      l_slot_step_x := l_col_step_x * l_slots;
      l_slot_step_z := l_step_z * l_slots;

      loop
        l_walked := l_walked + 1;
        if l_side_x < l_side_z then
          l_t_out := l_side_x;
        else
          l_t_out := l_side_z;
        end if;
        if l_t_out > l_near then
          l_b := l_focal / l_t_out;
        else
          l_b := l_near_f;
        end if; -- the one division per cell: a is the last cell's b (8.8)

        -- Draw the cell's spans: row(y) = h − (y − e_y) · f / t, at the near (a) or far (b) edge.
        l_n := pc_world.g_span_n(l_col + 1);
        if l_n > 0 then
          l_band := -1; -- Found at the cell's first fill since far cells mostly paint nothing
          l_kb := l_n - 1; -- on open land the eye is above every span so we need to loop
          while l_kb >= 0 and pc_world.g_span_y0(l_slot + l_kb) >= l_ey loop
            l_kb := l_kb - 1;
          end loop;
          if l_kb >= 0 then
            l_kb_top := edge(l_horizon - (pc_world.g_span_y1(l_slot + l_kb) - l_ey) * l_a, l_rows);
          end if;

          --  Walls, at the cell's near side, so nearer than anything else in it.
          if l_wall > 0 then

            for k in reverse 0 .. l_kb loop
              if k = l_kb then
                l_top := l_kb_top;
              else
                l_top := edge(l_horizon - (pc_world.g_span_y1(l_slot + k) - l_ey) * l_a, l_rows);
              end if;

              exit when l_prune and l_top > g_max_open;

              l_bottom := edge(l_horizon - (pc_world.g_span_y0(l_slot + k) - l_ey) * l_a, l_rows) - 1;

              if l_top <= l_bottom and l_bottom >= g_min_open and l_top <= g_max_open then
                if l_band < 0 then
                  l_fog := (l_t_in - g_fog_start) / g_fog_step; -- band = floor of this + 1, clamped to 0–3
                  l_band := case when l_fog < 0 then 0 when l_fog < 1 then 4 when l_fog < 2 then 8 else 12 end;
                end if;
                fill(l_top, l_bottom, pc_world.g_span_m(l_slot + k) * 16 + l_band + l_wall);
              end if;
            end loop;

            for k in l_kb + 1 .. l_n - 1 loop
              l_bottom := edge(l_horizon - (pc_world.g_span_y0(l_slot + k) - l_ey) * l_a, l_rows) - 1;
              exit when l_prune and l_bottom < g_min_open;
              l_top := edge(l_horizon - (pc_world.g_span_y1(l_slot + k) - l_ey) * l_a, l_rows);
              if l_top <= l_bottom and l_bottom >= g_min_open and l_top <= g_max_open then
                if l_band < 0 then
                  l_fog := (l_t_in - g_fog_start) / g_fog_step; -- band = floor of this + 1, clamped to 0–3
                  l_band := case when l_fog < 0 then 0 when l_fog < 1 then 4 when l_fog < 2 then 8 else 12 end;
                end if;
                fill(l_top, l_bottom, pc_world.g_span_m(l_slot + k) * 16 + l_band + l_wall);
              end if;
            end loop;
          end if;

          -- Tops of spans below the eye, highest first: a higher top is between the eye and a lower one.
          for k in reverse 0 .. l_kb loop
            l_y := pc_world.g_span_y1(l_slot + k);
            if l_y < l_ey and (k = l_n - 1 or pc_world.g_span_y0(l_slot + k + 1) != l_y) then -- buried otherwise
              l_top := edge(l_horizon - (l_y - l_ey) * l_b, l_rows);
              exit when l_prune and l_top > g_max_open;
              if k = l_kb then
                l_bottom := l_kb_top - 1;
              else
                l_bottom := edge(l_horizon - (l_y - l_ey) * l_a, l_rows) - 1;
              end if;
              if l_top <= l_bottom and l_bottom >= g_min_open and l_top <= g_max_open then
                if l_band < 0 then
                  l_fog := (l_t_in - g_fog_start) / g_fog_step; -- band = floor of this + 1, clamped to 0–3
                  l_band := case when l_fog < 0 then 0 when l_fog < 1 then 4 when l_fog < 2 then 8 else 12 end;
                end if;
                fill(l_top, l_bottom, pc_world.g_span_m(l_slot + k) * 16 + l_band); -- face 0
              end if;
            end if;
          end loop;

          -- Undersides of spans above the eye, lowest first.
          for k in l_kb + 1 .. l_n - 1 loop
            l_y := pc_world.g_span_y0(l_slot + k);
            l_bottom := edge(l_horizon - (l_y - l_ey) * l_b, l_rows) - 1;
            exit when l_prune and l_bottom < g_min_open;
            l_top := edge(l_horizon - (l_y - l_ey) * l_a, l_rows);
            if l_top <= l_bottom and l_bottom >= g_min_open and l_top <= g_max_open then
              if l_band < 0 then
                l_fog := (l_t_in - g_fog_start) / g_fog_step; -- band = floor of this + 1, clamped to 0–3
                l_band := case when l_fog < 0 then 0 when l_fog < 1 then 4 when l_fog < 2 then 8 else 12 end;
              end if;
              fill(l_top, l_bottom, pc_world.g_span_m(l_slot + k) * 16 + l_band + 3);
            end if;
          end loop;
        end if;

        -- (the column is full, the walk has passed FAR. So the rest of the walk is sky.
        exit when (l_prune and g_open = 0) or l_t_out > l_far;

        -- Step to the next cell, through an x-facing or a z-facing wall.
        if l_side_x < l_side_z then
          l_mx := l_mx + l_step_x;
          l_col := l_col + l_col_step_x;
          l_slot := l_slot + l_slot_step_x;
          l_side_x := l_side_x + l_each_x;
          l_wall := 1;
        else
          l_mz := l_mz + l_step_z;
          l_col := l_col + l_step_z;
          l_slot := l_slot + l_slot_step_z;
          l_side_z := l_side_z + l_each_z;
          l_wall := 2;
        end if;
        exit when l_mx not between 0 and pc_const.c_world_x - 1 or l_mz not between 0 and pc_const.c_world_z - 1;
        l_t_in := l_t_out;
        l_a := l_b;

        -- Every few cells: from here on every face lies between y = 0 and g_max_y and between t_in and
        -- FAR, so if no open row is in reach of that, everything still open is sky.

        l_until_check := l_until_check - 1;
        if l_prune and l_until_check = 0 then
          l_until_check := g_every;
          l_y := case when l_t_in > l_near then l_t_in else l_near end;
          l_reach_top := l_horizon - (l_max_y - l_ey) * l_focal / l_y;
          if l_far_top < l_reach_top then
            l_reach_top := l_far_top;
          end if;
          l_reach_top := l_reach_top - 1;
          l_reach_bottom := l_horizon + l_ey * l_focal / l_y;
          if l_far_bottom > l_reach_bottom then
            l_reach_bottom := l_far_bottom;
          end if;
          l_reach_bottom := l_reach_bottom + 1; -- a row of margin for rounding
          l_reach := false;
          for i in 1 .. g_open loop
            if g_lo(i) <= l_reach_bottom and g_hi(i) >= l_reach_top then
              l_reach := true;
              exit;
            end if;
          end loop;
          exit when not l_reach;
        end if;
        
      end loop;

      if g_heatmap then
        emit(0, l_height, least(l_walked, 255)); -- one colour that is  the number of cells walked 
      else
        -- Whatever is still open is sky, in four bands that lighten toward the horizon.
        l_sky1 := edge(l_horizon - 120, l_rows);
        l_sky2 := edge(l_horizon - 60, l_rows);
        l_sky3 := edge(l_horizon - 20, l_rows);
        for i in 1 .. g_open loop
          sky(g_lo(i), least(g_hi(i), l_sky1 - 1), 0);
          sky(greatest(g_lo(i), l_sky1), least(g_hi(i), l_sky2 - 1), 1);
          sky(greatest(g_lo(i), l_sky2), least(g_hi(i), l_sky3 - 1), 2);
          sky(greatest(g_lo(i), l_sky3), g_hi(i), 3);
        end loop;
      end if;
      end_column;
    end loop;
  end render;

end pc_render;