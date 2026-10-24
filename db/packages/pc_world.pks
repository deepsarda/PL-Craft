-- The world: generate, load, save, get and set blocks, rebuild spans (Sections 5 and 6). Engine lane.
-- While playing it holds the dense block array and the span cache in package state.
create or replace package pc_world as

  -- The span cache: each world column's solid runs, sorted bottom to top, at most 16.
  -- Public so the renderer can read it without copying; only this package writes it. VARRAYs, as benchmark
  -- B3 picked, so indexes start at 1:
  --   g_span_n(col + 1)            spans in world column col = x * 128 + z
  --   g_span_y0(col * 16 + k + 1)  bottom of span k; g_span_y1 its top (exclusive); g_span_m its material
  type t_span_counts is varray(16384) of pls_integer;  -- 128 × 128 columns
  type t_span_slots is varray(262144) of pls_integer;  -- 16 slots each
  g_span_n  t_span_counts := t_span_counts();
  g_span_y0 t_span_slots := t_span_slots();
  g_span_y1 t_span_slots := t_span_slots();
  g_span_m  t_span_slots := t_span_slots();

  -- Generates terrain (Section 6) and writes the world's PC_WORLDS row and all its PC_COLUMN rows, then commits.
  -- p_phase 1 is hills from 2D noise, and 2 adds arches and overhangs from 3D noise; null takes GEN_PHASE. The
  -- new world stays loaded in this session. Admin scripts call it once per world (Section 3.2).
  procedure generate(p_world_id in pls_integer, p_seed in pls_integer, p_phase in pls_integer default null);

  -- Generates a world under the next free world id, and returns the id.
  function new_world(p_seed in pls_integer, p_phase in pls_integer default null) return pls_integer;

  -- The unrounded height of column (x, z) in the last world built, from its seed and settings (Section 6.4).
  function height_map(p_x in pls_integer, p_z in pls_integer) return binary_double;

  -- Generates terrain into memory only, without touching tables, like clear. For tests.
  procedure build(p_seed in pls_integer, p_phase in pls_integer default null);

  -- The 64 blocks phase 1 gives a column of solid height p_height (Section 6.5), as hex, byte y at height y.
  function column_hex(p_height in pls_integer) return varchar2;

  -- Loads a world into memory: the block array, every column's spans and the highest span top (5.6).
  procedure load(p_world_id in pls_integer);

  -- Replaces the loaded world with one that lives only in memory, for tests: bedrock at y = 0 and stone
  -- below p_ground_top, air above. While it is loaded nothing is read from or written to tables.
  procedure clear(p_ground_top in pls_integer default 0);

  -- Material of one block; 0 (air) anywhere outside the world.
  function get_block(p_x in pls_integer, p_y in pls_integer, p_z in pls_integer) return pls_integer;

  -- The physics view (Section 5.3): solid outside x and z and below y = 0, air from y = 64 up.
  function is_solid(p_x in pls_integer, p_y in pls_integer, p_z in pls_integer) return boolean;

  -- Changes one block in memory and rebuilds that column's spans. Fails outside the world.
  procedure set_block(p_x in pls_integer, p_y in pls_integer, p_z in pls_integer, p_m in pls_integer);

  -- Saves one edit (Section 11.5): rewrites that column's PC_COLUMN row and adds a PC_EDIT_LOG row.
  -- Does not commit. Does nothing while a world made by clear() is loaded.
  procedure save_edit(
    p_x         in pls_integer,
    p_y         in pls_integer,
    p_z         in pls_integer,
    p_old_m     in pls_integer,
    p_new_m     in pls_integer,
    p_player_id in pls_integer);

  -- One above the highest solid block in the world, for the renderer's early-out (Section 8.6c).
  function max_y return pls_integer;

end pc_world;
/
