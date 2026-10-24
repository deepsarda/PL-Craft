-- Runtime defaults from Section 14. Names that are missing get their default; values already in the table
-- are kept, so tuning survives a reinstall. Change one with an UPDATE, then reconnect.

merge into pc_config c
using (values
  -- Rendering (14.1). Milestone 0 confirmed 640×360 at view distance 48 (db/bench/results.md).
  ('SCREEN_W', 640),
  ('SCREEN_H', 360),
  ('FOV_H_DEG', 90),
  ('FAR', 48),
  ('FOG_START', 24),
  ('PITCH_LIMIT_DEG', 55), 
  ('EARLYOUT_EVERY', 4),
  -- World and terrain, read at generation (14.2)
  ('GEN_PHASE', 1),
  ('SEA_LEVEL', 20),
  ('SNOW_LINE', 44),
  ('TERRAIN_BASE', 24),
  ('TERRAIN_AMP', 16),
  ('TERRAIN_FREQ', 0.015625),
  ('TERRAIN_OCTAVES', 4),
  ('TERRAIN_LACUNARITY', 2),
  ('TERRAIN_GAIN', 0.5),
  ('SQUASH', 8),
  ('DENSITY_FREQ_XZ', 32),
  ('DENSITY_FREQ_Y', 24),
  -- Player and physics (14.3)
  ('MOUSE_SENS', 0.0025),
  ('WALK_SPEED', 4.3),
  ('SPRINT_SPEED', 5.6),
  ('SNEAK_SPEED', 1.3),
  ('GRAVITY', 28),
  ('JUMP_HEIGHT', 1.25),
  ('TERMINAL_VEL', 40),
  ('MAX_DT', 0.1),
  ('REACH', 5),
  -- Saving (14.4)
  ('COMMIT_INTERVAL_S', 2),
  ('SAVE_INTERVAL_S', 10)
) d (name, value)
on (c.name = d.name)
when not matched then insert (name, value) values (d.name, d.value)
/
