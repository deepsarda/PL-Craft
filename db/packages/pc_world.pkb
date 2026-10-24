create or replace package body pc_world as

  -- Tests: T-W2 in db/tests/render.sql, generation and T-W3 in db/tests/world.sql. T-W1 still to write.

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

  -- The settings the last build used (Sections 6 and 14.2), recorded in the world's PC_WORLDS row.
  type t_gen is record (
    seed       pls_integer,
    phase      pls_integer,
    base       binary_double,
    amp        binary_double,
    freq       binary_double,
    octaves    pls_integer,
    lacunarity binary_double,
    gain       binary_double,
    squash     binary_double,
    freq_xz    binary_double,
    freq_y     binary_double,
    sea        pls_integer,
    snow       pls_integer);
  g_gen t_gen;

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

  -- Phase 1 materials (Section 6.5) at height p_y of a column whose solid height is p_height.
  function phase1_block(p_y in pls_integer, p_height in pls_integer, p_sea in pls_integer, p_snow in pls_integer)
    return pls_integer
  is
    l_beach constant boolean := p_height - 1 <= p_sea + 1; -- the top block at most one above sea level
  begin
    if p_y = 0 then
      return pc_const.c_bedrock;
    elsif p_y <= p_height - 5 then
      return pc_const.c_stone;
    elsif p_y <= p_height - 2 then
      return case when l_beach then pc_const.c_sand else pc_const.c_dirt end;
    elsif p_y = p_height - 1 then
      return case when l_beach then pc_const.c_sand when p_y >= p_snow then pc_const.c_snow else pc_const.c_grass end;
    elsif p_y < p_sea then
      return pc_const.c_water;
    end if;
    return pc_const.c_air;
  end phase1_block;

  -- Phase 1 (Section 6.5): a column whose solid height is p_height, with the last build's sea level and snow line.
  procedure materials(p_x in pls_integer, p_z in pls_integer, p_height in pls_integer) is
    l_base constant pls_integer := idx(p_x, 0, p_z);
  begin
    for y in 0 .. pc_const.c_world_y - 1 loop
      g_blocks(l_base + y) := phase1_block(y, p_height, g_gen.sea, g_gen.snow);
    end loop;
  end materials;

  function column_hex(p_height in pls_integer) return varchar2 is
    l_sea  constant pls_integer := pc_const.setting('SEA_LEVEL');
    l_snow constant pls_integer := pc_const.setting('SNOW_LINE');
    l_hex  varchar2(128);
  begin
    for y in 0 .. pc_const.c_world_y - 1 loop
      l_hex := l_hex || pc_const.g_hex(phase1_block(y, p_height, l_sea, l_snow));
    end loop;
    return l_hex;
  end column_hex;

  -- Phase 2 (Section 6.6), arches and overhangs: solid where noise3(x/32, y/24, z/32) + (h − y)/S > 0. Outside S of the surface the
  -- answer is known without noise. Then materials from the top down, and water in open air below sea level.
  procedure arches(p_x in pls_integer, p_z in pls_integer, p_h in binary_double) is
    l_base constant pls_integer := idx(p_x, 0, p_z);
    l_run  pls_integer := 0;              -- solid blocks since the last air block, counting from the top
    l_top  pls_integer := pc_const.c_air; -- the surface material over the current run
  begin
    for y in 0 .. pc_const.c_world_y - 1 loop
      g_blocks(l_base + y) :=                                -- for now 1 is solid and 0 is air
        case when y = 0 or y < p_h - g_gen.squash then 1     -- deep down: always solid
             when y > p_h + g_gen.squash then 0              -- high up: always air
             when pc_noise.noise3(p_x / g_gen.freq_xz, y / g_gen.freq_y, p_z / g_gen.freq_xz)
                  + (p_h - y) / g_gen.squash > 0 then 1
             else 0 end;
    end loop;
    for y in reverse 0 .. pc_const.c_world_y - 1 loop
      if g_blocks(l_base + y) = 0 then
        l_run := 0;
      elsif y = 0 then
        g_blocks(l_base + y) := pc_const.c_bedrock;
      else
        if l_run = 0 then -- the first solid block under air: grass, or sand or snow as in 6.5
          l_top := case when y <= g_gen.sea + 1 then pc_const.c_sand
                        when y >= g_gen.snow then pc_const.c_snow
                        else pc_const.c_grass end;
          g_blocks(l_base + y) := l_top;
        elsif l_run <= 3 then -- the next three: dirt, or sand under a beach as in 6.5
          g_blocks(l_base + y) := case when l_top = pc_const.c_sand then pc_const.c_sand else pc_const.c_dirt end;
        else
          g_blocks(l_base + y) := pc_const.c_stone;
        end if;
        l_run := l_run + 1;
      end if;
    end loop;
    for y in reverse 1 .. g_gen.sea - 1 loop -- open air below sea level is water, down to the ground
      exit when g_blocks(l_base + y) != pc_const.c_air;
      g_blocks(l_base + y) := pc_const.c_water;
    end loop;
  end arches;

  -- The height (6.4): B + A × fBm of 2D noise, between 8 and 40 with the defaults, for the last build's seed
  -- and settings. Phase 1 rounds it to the column's solid height; phase 2 uses it as it is.
  function height_map(p_x in pls_integer, p_z in pls_integer) return binary_double is
  begin
    return g_gen.base + g_gen.amp * pc_noise.fbm2(p_x * g_gen.freq, p_z * g_gen.freq, g_gen.octaves, g_gen.lacunarity, g_gen.gain);
  end height_map;

  procedure build(p_seed in pls_integer, p_phase in pls_integer default null) is
    l_h      binary_double;
    l_n      pls_integer;
  begin
    g_gen.seed := p_seed;
    g_gen.phase := nvl(p_phase, pc_const.setting('GEN_PHASE'));
    if g_gen.phase not in (1, 2) then
      raise_application_error(-20103, 'The terrain phase is 1 (hills) or 2 (hills with arches), not ' || g_gen.phase || '.');
    end if;
    g_gen.base := pc_const.setting('TERRAIN_BASE');
    g_gen.amp := pc_const.setting('TERRAIN_AMP');
    g_gen.freq := pc_const.setting('TERRAIN_FREQ');
    g_gen.octaves := pc_const.setting('TERRAIN_OCTAVES');
    g_gen.lacunarity := pc_const.setting('TERRAIN_LACUNARITY');
    g_gen.gain := pc_const.setting('TERRAIN_GAIN');
    g_gen.squash := pc_const.setting('SQUASH');
    g_gen.freq_xz := pc_const.setting('DENSITY_FREQ_XZ');
    g_gen.freq_y := pc_const.setting('DENSITY_FREQ_Y');
    g_gen.sea := pc_const.setting('SEA_LEVEL');
    g_gen.snow := pc_const.setting('SNOW_LINE');

    pc_noise.seed(p_seed);
    size_world;
    g_max_y := 0;
    for x in 0 .. pc_const.c_world_x - 1 loop
      for z in 0 .. pc_const.c_world_z - 1 loop
        l_h := height_map(x, z);
        if g_gen.phase = 1 then
          materials(x, z, greatest(2, least(60, round(l_h)))); -- H = round(h), clamped to 2–60
        else
          arches(x, z, l_h);
        end if;
        rebuild_spans(x, z);
        l_n := g_span_n(x * pc_const.c_world_z + z + 1);
        if l_n > 0 then
          g_max_y := greatest(g_max_y, g_span_y1((x * pc_const.c_world_z + z) * pc_const.c_max_spans + l_n));
        end if;
      end loop;
    end loop;
    g_world_id := null; -- only in memory until saved
  end build;

  -- One column's 64 blocks as PC_COLUMN.blocks: byte y is the material at height y.
  function column_raw(p_x in pls_integer, p_z in pls_integer) return raw is
    l_base constant pls_integer := idx(p_x, 0, p_z);
    l_hex  varchar2(128);
  begin
    for y in 0 .. pc_const.c_world_y - 1 loop
      l_hex := l_hex || pc_const.g_hex(g_blocks(l_base + y));
    end loop;
    return hextoraw(l_hex);
  end column_raw;

  -- Writes the world in memory as world p_world_id: its PC_WORLDS row and all its columns, in one bulk insert.
  procedure save_world(p_world_id in pls_integer) is
    type t_raws is table of raw(64) index by pls_integer;
    l_x      t_ints;
    l_z      t_ints;
    l_raw    t_raws;
    l_n      pls_integer := 0;
    l_params varchar2(1000);
  begin
    select json_object('terrain_base' value g_gen.base, 'terrain_amp' value g_gen.amp, 'terrain_freq' value g_gen.freq,
                       'terrain_octaves' value g_gen.octaves, 'terrain_lacunarity' value g_gen.lacunarity,
                       'terrain_gain' value g_gen.gain, 'squash' value g_gen.squash,
                       'density_freq_xz' value g_gen.freq_xz, 'density_freq_y' value g_gen.freq_y,
                       'sea_level' value g_gen.sea, 'snow_line' value g_gen.snow)
      into l_params
      from dual;
    merge into pc_worlds w
    using (select p_world_id world_id from dual) s
    on (w.world_id = s.world_id)
    when matched then
      update set seed = g_gen.seed, gen_version = g_gen.phase, gen_params = l_params, created_at = systimestamp
    when not matched then
      insert (world_id, seed, size_x, size_y, size_z, gen_version, gen_params)
      values (p_world_id, g_gen.seed, pc_const.c_world_x, pc_const.c_world_y, pc_const.c_world_z, g_gen.phase, l_params);

    delete from pc_column where world_id = p_world_id;
    for x in 0 .. pc_const.c_world_x - 1 loop
      for z in 0 .. pc_const.c_world_z - 1 loop
        l_n := l_n + 1;
        l_x(l_n) := x;
        l_z(l_n) := z;
        l_raw(l_n) := column_raw(x, z);
      end loop;
    end loop;
    forall i in 1 .. l_n
      insert into pc_column (world_id, x, z, blocks) values (p_world_id, l_x(i), l_z(i), l_raw(i));
    g_world_id := p_world_id;
    commit;
  end save_world;

  procedure generate(p_world_id in pls_integer, p_seed in pls_integer, p_phase in pls_integer default null) is
  begin
    build(p_seed, p_phase);
    save_world(p_world_id);
  end generate;

  function new_world(p_seed in pls_integer, p_phase in pls_integer default null) return pls_integer is
    l_world_id pls_integer;
  begin
    lock table pc_worlds in exclusive mode; -- two at once would take the same id; generate's commit releases it
    select nvl(max(world_id), 0) + 1 into l_world_id from pc_worlds;
    generate(l_world_id, p_seed, p_phase);
    return l_world_id;
  end new_world;

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
    l_blocks raw(64);
  begin
    if g_world_id is null then
      return;
    end if;
    l_blocks := column_raw(p_x, p_z);
    update pc_column set blocks = l_blocks where world_id = g_world_id and x = p_x and z = p_z;
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
