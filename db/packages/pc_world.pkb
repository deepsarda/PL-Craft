create or replace package body pc_world as

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

end pc_world;
/
