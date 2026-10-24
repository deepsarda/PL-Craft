create or replace package body pc_engine as

  -- STUB until pc_phys, pc_render and pc_frame exist. It does mouse look only, and every frame is sky over
  -- a flat grass plane split at the horizon row. That already proves the path the design rests on:
  -- package state survives between ticks on Node's dedicated connection, and the frame BLOB reaches the
  -- browser in the Section 9.1 format. Keys, clicks, p_dt and p_debug_heatmap are accepted and ignored.

  c_pi constant binary_double := acos(-1d);

  g_player_id pls_integer;
  g_width     pls_integer;
  g_height    pls_integer;
  g_focal     binary_double;
  g_sens      binary_double;
  g_pitch_max binary_double;
  g_px        binary_double;
  g_py        binary_double;
  g_pz        binary_double;
  g_yaw       binary_double;
  g_pitch     binary_double;
  g_held      pls_integer;
  g_frame     blob; -- one session-long temporary BLOB, trimmed and refilled every tick (Section 9.2)

  function cfg(p_name in varchar2, p_default in number) return number is
    l_value number;
  begin
    select max(value) into l_value from pc_config where name = p_name;
    return nvl(l_value, p_default);
  end cfg;

  -- Big-endian hex of an unsigned value, p_bytes long. No byte writes in PL/SQL, so frames are built as
  -- hex text and converted once (Section 9.2).
  function hex(p_value in number, p_bytes in pls_integer) return varchar2 is
  begin
    return lpad(to_char(p_value, 'fm' || rpad('X', p_bytes * 2, 'X')), p_bytes * 2, '0');
  end hex;

  procedure init_session(
    p_world_id      in pls_integer,
    p_player_id     in pls_integer,
    p_debug_heatmap in boolean default false)
  is
  begin
    g_player_id := p_player_id;
    g_width := cfg('SCREEN_W', 640);
    g_height := cfg('SCREEN_H', 360);
    g_focal := g_width / 2 / tan(cfg('FOV_H_DEG', 90) * c_pi / 360);
    g_sens := cfg('MOUSE_SENS', 0.0025);
    g_pitch_max := cfg('PITCH_LIMIT_DEG', 35) * c_pi / 180;

    -- A player seen for the first time starts standing in the middle of the world.
    merge into pc_player p
    using (select p_player_id player_id from dual) s
    on (p.player_id = s.player_id)
    when not matched then
      insert (player_id, world_id, name, px, py, pz, yaw, pitch, held, saved_at)
      values (p_player_id, p_world_id, 'Player ' || p_player_id, 64.5, 24, 64.5, 0, 0, pc_const.c_stone, systimestamp);
    commit;

    select px, py, pz, yaw, pitch, held
      into g_px, g_py, g_pz, g_yaw, g_pitch, g_held
      from pc_player
     where player_id = p_player_id;

    if g_frame is null then
      dbms_lob.createtemporary(g_frame, cache => true, dur => dbms_lob.session);
    end if;
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
    l_start   timestamp(6) with time zone := systimestamp;
    l_took    interval day to second;
    l_horizon pls_integer;
    l_runs    pls_integer;
    l_column  varchar2(32);
    l_body    varchar2(32767);
    l_frame   raw(32767);
  begin
    -- Mouse look (Section 10.2). Moving the mouse up gives a negative mdy, and up should look up.
    g_yaw := g_yaw + p_mdx * g_sens;
    g_yaw := g_yaw - 2 * c_pi * floor(g_yaw / (2 * c_pi));
    g_pitch := greatest(-g_pitch_max, least(g_pitch_max, g_pitch - p_mdy * g_sens));
    g_held := p_held;

    -- Every column is the same: sky down to the horizon row (Section 7.3), grass top face below it.
    l_horizon := greatest(0, least(g_height, round(g_height / 2 + g_focal * tan(g_pitch))));
    l_runs := case when l_horizon in (0, g_height) then 1 else 2 end;
    l_column := hex(l_runs, 2)
             || case when l_horizon > 0 then hex(0, 2) || hex(l_horizon, 2) || hex(3, 1) end
             || case when l_horizon < g_height then hex(l_horizon, 2) || hex(g_height - l_horizon, 2) || hex(pc_const.c_grass * 16, 1) end;
    for c in 1 .. g_width loop
      l_body := l_body || l_column;
    end loop;

    l_took := systimestamp - l_start;
    l_frame := hextoraw(
         '5043' || '01' || '00'                                   -- magic "PC", version 1, no flags
      || hex(p_seq, 4) || hex(g_width, 2) || hex(g_height, 2)
      || hex(round((extract(minute from l_took) * 60 + extract(second from l_took)) * 1e6), 4)
      || hex(0, 2) || hex(0, 2) || hex(0, 2) || '0000'             -- phys_us, edit_us, pack_us, reserved
      || hex(round(g_px * 1000), 4) || hex(round(g_py * 1000), 4) || hex(round(g_pz * 1000), 4)
      || hex(round(g_yaw * 1e4), 2) || hex(round(g_pitch * 1e4) + 32768, 2)
      || hex(g_held, 1) || 'FF' || hex(0, 2) || hex(0, 2) || hex(0, 2)  -- no target
      || hex(l_runs * g_width, 4)
      || l_body);

    dbms_lob.trim(g_frame, 0);
    dbms_lob.writeappend(g_frame, utl_raw.length(l_frame), l_frame);
    p_frame := g_frame;
  end tick;

  procedure shutdown is
  begin
    if g_player_id is not null then
      update pc_player
         set px = g_px, py = g_py, pz = g_pz, yaw = g_yaw, pitch = g_pitch, held = g_held, saved_at = systimestamp
       where player_id = g_player_id;
      commit;
    end if;
    if g_frame is not null then
      dbms_lob.freetemporary(g_frame);
      g_frame := null;
    end if;
  end shutdown;

end pc_engine;
/
