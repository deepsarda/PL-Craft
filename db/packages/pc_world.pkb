create or replace package body pc_world as

  -- Built except real terrain in generate (Section 6), which waits on pc_noise. Tests T-W2 here, T-W1 and
  -- T-W3 still to write.

  -- VARRAYs, as benchmark B3 picked: faster random reads than an associative array in 8 of 9 side-by-side
  -- rounds, and 26 MB for the 1,048,576 blocks against 30 MB (db/bench/results.md). The span cache uses them
  -- too. VARRAYs start at 1, so idx adds 1 (Section 13.3).
  type t_blocks is varray(1048576) of pls_integer; -- 128 × 64 × 128
  type t_ints is table of pls_integer index by pls_integer;
  type t_by_hex is table of pls_integer index by varchar2(2);

  g_blocks   t_blocks := t_blocks(); -- idx(x, y, z) = (x * 128 + z) * 64 + y + 1 (Section 5.3)
  g_world_id pls_integer;      -- null while a world made by clear() is loaded
  g_max_y    pls_integer := 0; -- one above the highest solid block
  g_value    t_by_hex;         -- 'A7' → 167, for unpacking PC_COLUMN.blocks

  function idx(p_x in pls_integer, p_y in pls_integer, p_z in pls_integer) return pls_integer is
  begin
    return (p_x * pc_const.c_world_z + p_z) * pc_const.c_world_y + p_y + 1;
  end idx;

  -- Every block and span slot present, so no read ever misses (Section 13.3). Sized once; reloads reuse them.
  procedure size_world is
    c_columns constant pls_integer := pc_const.c_world_x * pc_const.c_world_z;
  begin
    if g_blocks.count = 0 then
      g_blocks.extend(c_columns * pc_const.c_world_y);
      g_span_n.extend(c_columns);
      g_span_y0.extend(c_columns * pc_const.c_max_spans);
      g_span_y1.extend(c_columns * pc_const.c_max_spans);
      g_span_m.extend(c_columns * pc_const.c_max_spans);
    end if;
  end size_world;

  function inside(p_x in pls_integer, p_y in pls_integer, p_z in pls_integer) return boolean is
  begin
    return p_x between 0 and pc_const.c_world_x - 1
       and p_y between 0 and pc_const.c_world_y - 1
       and p_z between 0 and pc_const.c_world_z - 1;
  end inside;

  -- Turns one column's 64 blocks into its spans (Section 5.4): a span closes where the material changes, and
  -- a new one opens unless the block is air.
  procedure rebuild_spans(p_x in pls_integer, p_z in pls_integer) is
    l_col   constant pls_integer := p_x * pc_const.c_world_z + p_z;
    l_slot  constant pls_integer := l_col * pc_const.c_max_spans + 1; -- span 0's slot
    l_block constant pls_integer := idx(p_x, 0, p_z);
    l_n     pls_integer := 0;
    l_open  pls_integer := pc_const.c_air; -- material of the open span; air when none is open
    l_m     pls_integer;
  begin
    for y in 0 .. pc_const.c_world_y - 1 loop
      l_m := g_blocks(l_block + y);
      if l_m != l_open then
        if l_open != pc_const.c_air then
          g_span_y1(l_slot + l_n - 1) := y;
        end if;
        if l_m != pc_const.c_air then
          if l_n = pc_const.c_max_spans then
            -- A 17th span would open: the 16th runs to the top of the column instead. Natural terrain never
            -- gets here; striped towers do.
            g_span_y1(l_slot + l_n - 1) := pc_const.c_world_y;
            l_open := pc_const.c_air;
            dbms_output.put_line('pc_world: column (' || p_x || ', ' || p_z || ') has more than 16 spans');
            exit;
          end if;
          g_span_y0(l_slot + l_n) := y;
          g_span_m(l_slot + l_n) := l_m;
          l_n := l_n + 1;
        end if;
        l_open := l_m;
      end if;
    end loop;
    if l_open != pc_const.c_air then
      g_span_y1(l_slot + l_n - 1) := pc_const.c_world_y;
    end if;
    g_span_n(l_col + 1) := l_n;
  end rebuild_spans;

  function height_map(p_x in pls_integer, p_z in pls_integer) return binary_double is
  begin
    return pc_const.c_terrain_base
         + pc_const.c_terrain_amp
           * pc_noise.fbm2(
               p_x * pc_const.c_terrain_freq,
               p_z * pc_const.c_terrain_freq,
               pc_const.c_terrain_octaves,
               pc_const.c_terrain_lacunarity,
               pc_const.c_terrain_gain);
  end height_map;
  
  procedure materials(
    p_col in out nocopy t_blocks,
    p_base in pls_integer,            -- idx(x, 0, z)
    p_h in pls_integer,            -- solid height H  (clamped 2..60)
    p_sea in pls_integer,
    p_snow in pls_integer)
  is
    l_top pls_integer;                 -- material for the top block
    l_mid pls_integer;                 -- material for the 3 layers under the top
  begin
    -- Decide top + mid materials
    if p_h - 1 <= p_sea + 1 then       -- beach: top of ground at or below sea_level + 1
      l_top := pc_const.c_sand;
      l_mid := pc_const.c_sand;
    elsif p_h - 1 >= p_snow then        -- snow line
      l_top := pc_const.c_snow;
      l_mid := pc_const.c_dirt;
    else
      l_top := pc_const.c_grass;
      l_mid := pc_const.c_dirt;
    end if;

    for y in 0 .. pc_const.c_world_y - 1 loop
      if y = 0 then
        p_col(p_base + y) := pc_const.c_bedrock;
      elsif y <= p_h - 5 then
        p_col(p_base + y) := pc_const.c_stone;
      elsif y <= p_h - 2 then
        p_col(p_base + y) := l_mid;
      elsif y = p_h - 1 then
        p_col(p_base + y) := l_top;
      elsif y < p_sea and y >= p_h then
        p_col(p_base + y) := pc_const.c_water;
      else
        p_col(p_base + y) := pc_const.c_air;
      end if;
    end loop;
  end materials_phase1;

  procedure arches(
    p_col in out nocopy t_blocks,
    p_base in pls_integer,         
    p_x in pls_integer,
    p_z in pls_integer,
    p_h_raw in binary_double,      
    p_squash in binary_double,
    p_freq_xz in binary_double,
    p_freq_y in binary_double,
    p_sea in pls_integer,
    p_snow in pls_integer)
  is
    l_y_lo  pls_integer;               -- bottom of the evaluation band
    l_y_hi  pls_integer;               -- top of the evaluation band  (inclusive)
    l_d     binary_double;
    l_h_int pls_integer;               -- clamped integer height for fall-back
    l_depth pls_integer := 0;          -- blocks since last air  (for material assignment)
    l_top   pls_integer;               -- top material for this column
  begin
    -- Band limits, clamped into the world
    l_y_lo := greatest(1, floor(p_h_raw - p_squash));
    l_y_hi := least(pc_const.c_world_y - 1, ceil(p_h_raw + p_squash));
    l_h_int := greatest(2, least(60, round(p_h_raw)));

    -- Pass 1: decide solid / air for every block in the column
    -- Below the band: always solid (stone placeholder; materials overwrite later)
    for y in 0 .. pc_const.c_world_y - 1 loop
      if y = 0 then
        p_col(p_base + y) := pc_const.c_bedrock;
      elsif y < l_y_lo then
        p_col(p_base + y) := pc_const.c_stone;
      elsif y <= l_y_hi then
        -- Inside the band: evaluate the density field
        l_d := pc_noise.noise3(p_x / p_freq_xz, y / p_freq_y, p_z / p_freq_xz)
             + (p_h_raw - y) / p_squash;
        if l_d > 0 then
          p_col(p_base + y) := pc_const.c_stone;   -- solid placeholder
        elsif y < p_sea then
          p_col(p_base + y) := pc_const.c_water;
        else
          p_col(p_base + y) := pc_const.c_air;
        end if;
      elsif y < p_sea then
        p_col(p_base + y) := pc_const.c_water;
      else
        p_col(p_base + y) := pc_const.c_air;
      end if;
    end loop;

    -- Pass 2: assign materials top-down  (Section 6.6 "Materials after phase 2")
    -- Decide the top-surface material the same way as phase 1.
    if l_h_int - 1 <= p_sea + 1 then
      l_top := pc_const.c_sand;
    elsif l_h_int - 1 >= p_snow then
      l_top := pc_const.c_snow;
    else
      l_top := pc_const.c_grass;
    end if;

    l_depth := 0;
    for y in reverse 1 .. pc_const.c_world_y - 1 loop
      if p_col(p_base + y) = pc_const.c_air or p_col(p_base + y) = pc_const.c_water then
        l_depth := 0;  -- reset: we are in air / water
      else
        -- solid block
        l_depth := l_depth + 1;
        if l_depth = 1 then
          p_col(p_base + y) := l_top;        -- first solid under air
        elsif l_depth <= 4 then
          if l_top = pc_const.c_sand then
            p_col(p_base + y) := pc_const.c_sand;
          else
            p_col(p_base + y) := pc_const.c_dirt;
          end if;
        else
          p_col(p_base + y) := pc_const.c_stone;
        end if;
      end if;
    end loop;
    -- y = 0 stays bedrock (set in pass 1)
  end arches;


  procedure generate(p_world_id in pls_integer, p_seed in pls_integer) is
    l_phase    pls_integer := pc_const.setting('GEN_PHASE');
    l_sea      pls_integer := pc_const.setting('SEA_LEVEL');
    l_snow     pls_integer := pc_const.setting('SNOW_LINE');
    l_squash   binary_double;
    l_freq_xz  binary_double;
    l_freq_y   binary_double;
    l_h_raw    binary_double;
    l_h        pls_integer;
    l_base     pls_integer;
    l_hex      varchar2(128);
  begin
    -- Seed the noise generator
    pc_noise.seed(p_seed);

    -- Phase 2 settings (read only when needed)
    if l_phase >= 2 then
      l_squash  := pc_const.setting('SQUASH');
      l_freq_xz := pc_const.setting('DENSITY_FREQ_XZ');
      l_freq_y  := pc_const.setting('DENSITY_FREQ_Y');
    end if;

    -- Ensure block array is sized
    size_world;

    -- Build every column
    for x in 0 .. pc_const.c_world_x - 1 loop
      for z in 0 .. pc_const.c_world_z - 1 loop
        l_base := idx(x, 0, z);

        -- 6.4  Height map
        l_h_raw := height_map(x, z);
        l_h     := greatest(2, least(60, round(l_h_raw)));

        if l_phase >= 2 then
          -- 6.6  Arches and overhangs (includes its own material pass)
          arches(g_blocks, l_base, x, z, l_h_raw, l_squash, l_freq_xz, l_freq_y, l_sea, l_snow);
        else
          -- 6.5  Materials (phase 1 only)
          materials_phase1(g_blocks, l_base, l_h, l_sea, l_snow);
        end if;

        -- Track the highest solid block
        for y in reverse 0 .. pc_const.c_world_y - 1 loop
          if g_blocks(l_base + y) != pc_const.c_air
             and g_blocks(l_base + y) != pc_const.c_water then
            if y + 1 > g_max_y then
              g_max_y := y + 1;
            end if;
            exit;
          end if;
        end loop;

        rebuild_spans(x, z);
      end loop;
    end loop;

    -- Persist to tables
    merge into pc_worlds w
    using (select p_world_id world_id from dual) s
    on (w.world_id = s.world_id)
    when matched then update set seed = p_seed, gen_version = l_phase, created_at = systimestamp
    when not matched then
      insert (world_id, seed, size_x, size_y, size_z, gen_version)
      values (p_world_id, p_seed, pc_const.c_world_x, pc_const.c_world_y, pc_const.c_world_z, l_phase);

    delete from pc_column where world_id = p_world_id;
    for x in 0 .. pc_const.c_world_x - 1 loop
      for z in 0 .. pc_const.c_world_z - 1 loop
        l_base := idx(x, 0, z);
        l_hex := '';
        for y in 0 .. pc_const.c_world_y - 1 loop
          l_hex := l_hex || pc_const.g_hex(g_blocks(l_base + y));
        end loop;
        insert into pc_column (world_id, x, z, blocks)
        values (p_world_id, x, z, hextoraw(l_hex));
      end loop;
    end loop;
    commit;
  end generate;

  procedure load(p_world_id in pls_integer) is
    type t_hexes is table of varchar2(128) index by pls_integer;
    l_x    t_ints;
    l_z    t_ints;
    l_hex  t_hexes;
    l_base pls_integer;
    l_m    pls_integer;
  begin
    select x, z, rawtohex(blocks) bulk collect into l_x, l_z, l_hex
      from pc_column
     where world_id = p_world_id;
    if l_x.count != pc_const.c_world_x * pc_const.c_world_z then
      raise_application_error(-20101, 'World ' || p_world_id || ' has ' || l_x.count || ' of its '
        || pc_const.c_world_x * pc_const.c_world_z || ' columns. Generate it first: exec pc_world.generate('
        || p_world_id || ', <seed>)');
    end if;

    size_world;
    g_max_y := 0;
    for i in 1 .. l_x.count loop
      l_base := idx(l_x(i), 0, l_z(i));
      for y in 0 .. pc_const.c_world_y - 1 loop
        l_m := g_value(substr(l_hex(i), 2 * y + 1, 2));
        g_blocks(l_base + y) := l_m;
        if l_m != pc_const.c_air and y >= g_max_y then
          g_max_y := y + 1;
        end if;
      end loop;
      rebuild_spans(l_x(i), l_z(i));
    end loop;
    g_world_id := p_world_id;
  end load;

  procedure clear(p_ground_top in pls_integer default 0) is
    l_base pls_integer;
  begin
    size_world;
    for x in 0 .. pc_const.c_world_x - 1 loop
      for z in 0 .. pc_const.c_world_z - 1 loop
        l_base := idx(x, 0, z);
        for y in 0 .. pc_const.c_world_y - 1 loop
          g_blocks(l_base + y) := case when y >= p_ground_top then pc_const.c_air
                                       when y = 0 then pc_const.c_bedrock
                                       else pc_const.c_stone end;
        end loop;
        rebuild_spans(x, z);
      end loop;
    end loop;
    g_max_y := greatest(0, least(pc_const.c_world_y, p_ground_top));
    g_world_id := null;
  end clear;

  function get_block(p_x in pls_integer, p_y in pls_integer, p_z in pls_integer) return pls_integer is
  begin
    if not inside(p_x, p_y, p_z) then
      return pc_const.c_air;
    end if;
    return g_blocks(idx(p_x, p_y, p_z));
  end get_block;

  function is_solid(p_x in pls_integer, p_y in pls_integer, p_z in pls_integer) return boolean is
  begin
    if p_x not between 0 and pc_const.c_world_x - 1 or p_z not between 0 and pc_const.c_world_z - 1 or p_y < 0 then
      return true; -- an invisible wall at the world's edge, and a floor below it
    end if;
    if p_y >= pc_const.c_world_y then
      return false;
    end if;
    return g_blocks(idx(p_x, p_y, p_z)) != pc_const.c_air;
  end is_solid;

  procedure set_block(p_x in pls_integer, p_y in pls_integer, p_z in pls_integer, p_m in pls_integer) is
  begin
    if not inside(p_x, p_y, p_z) then
      raise_application_error(-20102, 'Block (' || p_x || ', ' || p_y || ', ' || p_z || ') is outside the world.');
    end if;
    g_blocks(idx(p_x, p_y, p_z)) := p_m;
    rebuild_spans(p_x, p_z);
    if p_m != pc_const.c_air and p_y >= g_max_y then
      g_max_y := p_y + 1;
    end if;
  end set_block;

  procedure save_edit(
    p_x         in pls_integer,
    p_y         in pls_integer,
    p_z         in pls_integer,
    p_old_m     in pls_integer,
    p_new_m     in pls_integer,
    p_player_id in pls_integer)
  is
    l_base pls_integer := idx(p_x, 0, p_z);
    l_hex  varchar2(128);
  begin
    if g_world_id is null then
      return;
    end if;
    for y in 0 .. pc_const.c_world_y - 1 loop
      l_hex := l_hex || pc_const.g_hex(g_blocks(l_base + y));
    end loop;
    update pc_column set blocks = hextoraw(l_hex) where world_id = g_world_id and x = p_x and z = p_z;
    insert into pc_edit_log (world_id, x, y, z, old_m, new_m, player_id)
    values (g_world_id, p_x, p_y, p_z, p_old_m, p_new_m, p_player_id);
  end save_edit;

  function max_y return pls_integer is
  begin
    return g_max_y;
  end max_y;

begin
  for i in 0 .. 255 loop
    g_value(pc_const.g_hex(i)) := i;
  end loop;
end pc_world;
/
