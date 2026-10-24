create or replace package body pc_world as

  -- The block store is built; still owed by the engine lane are the span cache that rebuild_spans should
  -- fill (5.4) and real terrain in generate (Section 6). Tests T-W1 to T-W3.

  -- A VARRAY, as benchmark B3 picked: faster random reads than an associative array in 8 of 9 side-by-side
  -- rounds, and 26 MB for the 1,048,576 blocks against 30 MB (db/bench/results.md). Use it for the span cache
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

  -- Every block present, so no read ever misses (Section 13.3). Sized once; reloads reuse it.
  procedure size_blocks is
  begin
    if g_blocks.count = 0 then
      g_blocks.extend(pc_const.c_world_x * pc_const.c_world_y * pc_const.c_world_z);
    end if;
  end size_blocks;

  function inside(p_x in pls_integer, p_y in pls_integer, p_z in pls_integer) return boolean is
  begin
    return p_x between 0 and pc_const.c_world_x - 1
       and p_y between 0 and pc_const.c_world_y - 1
       and p_z between 0 and pc_const.c_world_z - 1;
  end inside;

  -- STUB: should turn the column's 64 blocks into at most 16 spans, with the overflow rule (Section 5.4).
  procedure rebuild_spans(p_x in pls_integer, p_z in pls_integer) is
  begin
    null;
  end rebuild_spans;

  -- STUB until pc_noise exists (Section 6): a flat world. Bedrock at y = 0, stone 1–19, dirt 20–22 and
  -- grass at 23, which is Section 6.5 with H = 24, so a player's feet rest at y = 24. p_seed is only stored.
  procedure generate(p_world_id in pls_integer, p_seed in pls_integer) is
    l_blocks raw(64) := hextoraw('01' || rpad('02', 38, '02') || '030303' || '04' || rpad('00', 80, '00'));
  begin
    merge into pc_worlds w
    using (select p_world_id world_id from dual) s
    on (w.world_id = s.world_id)
    when matched then update set seed = p_seed, gen_version = 0, created_at = systimestamp
    when not matched then
      insert (world_id, seed, size_x, size_y, size_z, gen_version)
      values (p_world_id, p_seed, pc_const.c_world_x, pc_const.c_world_y, pc_const.c_world_z, 0);

    delete from pc_column where world_id = p_world_id;
    insert into pc_column (world_id, x, z, blocks)
      select p_world_id, trunc((level - 1) / pc_const.c_world_z), mod(level - 1, pc_const.c_world_z), l_blocks
        from dual
     connect by level <= pc_const.c_world_x * pc_const.c_world_z;
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

    size_blocks;
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
    size_blocks;
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
