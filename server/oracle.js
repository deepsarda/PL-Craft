// One player's Oracle session (Section 12.2). A dedicated connection, never a pool: the world and the
// player live in this session's package state, so every tick must reach the same session (Section 12.1).
import oracledb from 'oracledb';

const FRAME_MAX_BYTES = Number(process.env.FRAME_MAX_BYTES ?? 1_200_000); // above the 1.15 MB worst case

// Package state was discarded, almost always because someone recompiled a package mid-game.
const STATE_DISCARDED = new Set([4068, 4061, 4065]);

const INIT = `begin
  pc_engine.init_session(p_world_id => :world_id, p_player_id => :player_id, p_debug_heatmap => :debug_heatmap);
end;`;

const TICK = `begin
  pc_engine.tick(p_seq => :seq, p_keys => :keys, p_mdx => :mdx, p_mdy => :mdy, p_lclick => :lclick,
                 p_rclick => :rclick, p_held => :held, p_dt => null, p_frame => :frame);
end;`;

// Saves the player and edits in the world being left, then makes a world and moves the player into it.
const NEW_WORLD = `declare
  l_world_id pls_integer;
begin
  pc_engine.save;
  l_world_id := pc_world.new_world(p_seed => :seed, p_phase => :phase);
  pc_engine.init_session(p_world_id => l_world_id, p_player_id => :player_id, p_debug_heatmap => :debug_heatmap);
  :world_id := l_world_id;
end;`;

const JOIN = `begin
  pc_engine.save;
  pc_engine.init_session(p_world_id => :world_id, p_player_id => :player_id, p_debug_heatmap => :debug_heatmap);
end;`;

const WORLDS = `select world_id, seed, gen_version, to_char(created_at, 'YYYY-MM-DD HH24:MI') from pc_worlds order by world_id`;

// What the browser needs before the first frame: screen size, and the FOV to project the target outline.
const SCREEN = `select nvl(max(case name when 'SCREEN_W' then to_number(value) end), 640),
       nvl(max(case name when 'SCREEN_H' then to_number(value) end), 360),
       nvl(max(case name when 'FOV_H_DEG' then to_number(value) end), 90)
  from pc_config`;

// Connection settings from .env (names as in PLCRAFT-LINUX-SETUP.md), or null when any is missing.
export function dbSettings() {
  const { PLCRAFT_DB_USER: user, PLCRAFT_DB_PASSWORD: password, PLCRAFT_DB_CONNECT_STRING: connectString } = process.env;
  return user && password && connectString ? { user, password, connectString } : null;
}

export async function openOracle({ worldId, playerId, debugHeatmap }) {
  const conn = await oracledb.getConnection(dbSettings());
  let world = worldId; // changes when the player makes or joins another world
  const init = () => conn.execute(INIT, { world_id: world, player_id: playerId, debug_heatmap: debugHeatmap });
  let screen;
  try {
    await init();
    [screen] = (await conn.execute(SCREEN)).rows;
  } catch (err) {
    await conn.close().catch(() => {});
    throw err;
  }

  const frame = { dir: oracledb.BIND_OUT, type: oracledb.BUFFER, maxSize: FRAME_MAX_BYTES };
  const tick = async input => (await conn.execute(TICK, { ...input, frame })).outBinds.frame;
  const [width, height, fov] = screen;

  return {
    width,
    height,
    fov,
    async tick(input) {
      try {
        return await tick(input);
      } catch (err) {
        if (!STATE_DISCARDED.has(err.errorNum)) throw err;
        await init(); // reload the world from its tables, then retry this input once
        return tick(input);
      }
    },
    async save() {
      await conn.execute('begin pc_engine.save; end;'); // the player, and a commit
    },
    async worlds() {
      const { rows } = await conn.execute(WORLDS);
      return rows.map(([id, seed, phase, created]) => ({ world_id: id, seed, phase, created }));
    },
    async newWorld(seed, phase) {
      const r = await conn.execute(NEW_WORLD, {
        seed, phase, player_id: playerId, debug_heatmap: debugHeatmap,
        world_id: { dir: oracledb.BIND_OUT, type: oracledb.NUMBER },
      });
      world = r.outBinds.world_id;
      return world;
    },
    async join(id) {
      await conn.execute(JOIN, { world_id: id, player_id: playerId, debug_heatmap: debugHeatmap });
      world = id;
    },
    lost: () => !conn.isHealthy(),
    async shutdown() {
      try {
        await conn.execute('begin pc_engine.shutdown; end;'); // saves the player and commits
      } finally {
        await conn.close();
      }
    },
  };
}
