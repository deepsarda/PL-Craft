-- The column renderer (Sections 7 and 8). Engine lane.
create or replace package pc_render as

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

end pc_render;
/
