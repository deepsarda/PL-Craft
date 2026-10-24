-- Compile-time constants (Sections 5 and 14). Changing a size means recompiling, and usually a new world.
create or replace package pc_const as
  c_world_x    constant simple_integer := 128;
  c_world_y    constant simple_integer := 64;  -- fixed in v1: PC_COLUMN.blocks is RAW(64)
  c_world_z    constant simple_integer := 128;
  c_max_spans  constant simple_integer := 16;
  c_t_near     constant binary_double := 0.05d;
  c_substep    constant binary_double := 1d / 60d;
  c_eye_height constant binary_double := 1.62d;

  -- Materials (Section 5.2)
  c_air         constant simple_integer := 0;
  c_bedrock     constant simple_integer := 1;
  c_stone       constant simple_integer := 2;
  c_dirt        constant simple_integer := 3;
  c_grass       constant simple_integer := 4;
  c_sand        constant simple_integer := 5;
  c_water       constant simple_integer := 6;
  c_log         constant simple_integer := 7;
  c_leaves      constant simple_integer := 8;
  c_planks      constant simple_integer := 9;
  c_cobblestone constant simple_integer := 10;
  c_brick       constant simple_integer := 11;
  c_snow        constant simple_integer := 12;
end pc_const;
/
