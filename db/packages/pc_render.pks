-- The column renderer (Sections 7 and 8): one ray per screen column across the world's span cache, painted
-- front to back into a coverage list, so the first thing to claim a row is always the nearest. Engine lane.
create or replace package pc_render as

  -- The early-outs (a) to (c) of Section 8.6 may only skip work, never change a pixel. Tests turn them off
  -- to check exactly that (T-R5).
  g_early_outs boolean := true;

  -- Reads the rendering settings (Section 14.1) and precomputes what depends only on the screen (7.2).
  procedure init(p_debug_heatmap in boolean default false);

  -- Renders one frame from the eye into pc_frame: for every screen column, left to right, its runs
  -- (pc_frame.run) and then pc_frame.end_column. The caller has called pc_frame.begin_frame.
  procedure render(
    p_eye_x in binary_double,
    p_eye_y in binary_double,
    p_eye_z in binary_double,
    p_yaw   in binary_double,
    p_pitch in binary_double);

  -- True when render paints walk-length heat maps instead of colours (Section 9.5, header flag bit 2).
  function heatmap return boolean;

  -- The coverage list (Section 8.5), public so tests can drive it (T-R2). reset_coverage opens rows 0 to
  -- p_height − 1; fill paints whichever of rows p_a to p_b are still open, as runs in pc_frame; end_column
  -- hands over the column's last run and closes the column in pc_frame.
  procedure reset_coverage(p_height in pls_integer);
  procedure fill(p_a in pls_integer, p_b in pls_integer, p_index in pls_integer);
  procedure end_column;

end pc_render;
/
