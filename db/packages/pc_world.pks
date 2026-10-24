-- The world: generate, load, save, get and set blocks, rebuild spans (Sections 5 and 6).
-- While playing it holds the dense block array and the span cache in package state.
create or replace package pc_world as
  -- Writes PC_WORLD and all PC_COLUMN rows for one world. Admin script, once per world (Section 3.2).
  procedure generate(p_world_id in pls_integer, p_seed in pls_integer);
end pc_world;
/
