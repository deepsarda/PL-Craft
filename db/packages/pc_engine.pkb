create or replace package body pc_engine as

  g_commit_every binary_double;               -- COMMIT_INTERVAL_S (Section 11.5)
  g_save_every   binary_double;               -- SAVE_INTERVAL_S
  g_last_commit  timestamp(6) with time zone;
  g_last_save    timestamp(6) with time zone;
  g_dirty        boolean := false;            -- edits or a player save not committed yet

  procedure init_session(
    p_world_id      in pls_integer,
    p_player_id     in pls_integer,
    p_debug_heatmap in boolean default false)
  is
  begin
    pc_world.load(p_world_id);
    pc_phys.init;
    pc_phys.load(p_player_id, p_world_id);
    commit; -- the row of a player seen for the first time
    pc_render.init(p_debug_heatmap);
    pc_frame.init(pc_const.setting('SCREEN_W'), pc_const.setting('SCREEN_H'));
    g_commit_every := pc_const.setting('COMMIT_INTERVAL_S');
    g_save_every := pc_const.setting('SAVE_INTERVAL_S');
    g_last_commit := systimestamp;
    g_last_save := systimestamp;
    g_dirty := false;
  end init_session;

  procedure tick(
    p_seq    in pls_integer,
    p_keys   in pls_integer,
    p_mdx    in pls_integer,
    p_mdy    in pls_integer,
    p_lclick in pls_integer,
    p_rclick in pls_integer,
    p_held   in pls_integer,
    p_dt     in binary_double,
    p_frame  out blob)
  is
    l_began  timestamp(6) with time zone := systimestamp;
    l_stage  timestamp(6) with time zone;
    l_edited boolean := false;
    l_hit    pc_phys.t_hit;
    l_header pc_frame.t_header;
  begin
    -- 1–2. Mouse look, then physics.
    pc_phys.look(p_mdx, p_mdy);
    pc_phys.step(p_keys, p_dt);
    l_header.phys_us := pc_const.seconds_since(l_began) * 1e6;

    -- 3–4. Break, then place, each raycasting from the new eye. edit_us stays 0 without a click.
    if p_lclick = 1 or p_rclick = 1 then
      l_stage := systimestamp;
      if p_lclick = 1 and pc_phys.break_block then
        l_edited := true;
      end if;
      if p_rclick = 1 and pc_phys.place_block(p_held) then
        l_edited := true;
      end if;
      l_header.edit_us := pc_const.seconds_since(l_stage) * 1e6;
    end if;
    if pc_const.placeable(p_held) then
      pc_phys.g_player.held := p_held;
    end if;

    -- Saving (Section 11.5): the player every SAVE_INTERVAL_S, and at most one commit per
    -- COMMIT_INTERVAL_S, because a commit waits on a disk write that can blow a frame's budget.
    if pc_const.seconds_since(g_last_save) >= g_save_every then
      pc_phys.save;
      g_last_save := systimestamp;
      g_dirty := true;
    end if;
    g_dirty := g_dirty or l_edited;
    if g_dirty and pc_const.seconds_since(g_last_commit) >= g_commit_every then
      commit;
      g_last_commit := systimestamp;
      g_dirty := false;
    end if;

    -- 5. Render.
    l_stage := systimestamp;
    pc_frame.begin_frame;
    pc_render.render(pc_phys.g_player.px, pc_phys.g_player.py + pc_const.c_eye_height, pc_phys.g_player.pz,
                     pc_phys.g_player.yaw, pc_phys.g_player.pitch);
    l_header.render_us := pc_const.seconds_since(l_stage) * 1e6;

    -- 6. Pack, with what the crosshair is on now so the browser can outline it.
    l_hit := pc_phys.raycast;
    l_header.flags := case when l_hit.hit then 1 else 0 end
                    + case when l_edited then 2 else 0 end
                    + case when pc_render.heatmap then 4 else 0 end;
    l_header.seq := p_seq;
    l_header.px := pc_phys.g_player.px;
    l_header.py := pc_phys.g_player.py;
    l_header.pz := pc_phys.g_player.pz;
    l_header.yaw := pc_phys.g_player.yaw;
    l_header.pitch := pc_phys.g_player.pitch;
    l_header.held := pc_phys.g_player.held;
    if l_hit.hit then
      l_header.target_face := l_hit.face;
      l_header.target_x := l_hit.x;
      l_header.target_y := l_hit.y;
      l_header.target_z := l_hit.z;
    end if;
    pc_frame.finish(l_header, p_frame);
  end tick;

  procedure save is
  begin
    pc_phys.save;
    commit;
    g_last_save := systimestamp;
    g_last_commit := g_last_save;
    g_dirty := false;
  end save;

  procedure shutdown is
  begin
    if pc_phys.g_player.player_id is not null then
      save;
    end if;
    pc_frame.free;
  end shutdown;

end pc_engine;
/
