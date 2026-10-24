-- The player: mouse look, movement, collision, the block raycast, and breaking and placing blocks
-- (Sections 10 and 11). Platform lane.
create or replace package pc_phys as

  -- The one player of this session (Section 5.5).
  type t_player is record (
    player_id pls_integer,
    px        binary_double,         -- feet: the centre of the bottom of the box
    py        binary_double,
    pz        binary_double,
    vx        binary_double := 0,    -- blocks per second
    vy        binary_double := 0,
    vz        binary_double := 0,
    yaw       binary_double := 0,    -- radians, 0 faces east (+x), increasing toward south (+z)
    pitch     binary_double := 0,    -- radians, positive looks up
    on_ground boolean := false,
    held      pls_integer := pc_const.c_stone,
    last_tick timestamp(6) with time zone);
  g_player t_player;

  -- What the crosshair is on (Section 11.1).
  type t_hit is record (
    hit    boolean := false,
    x      pls_integer,              -- the block hit
    y      pls_integer,
    z      pls_integer,
    prev_x pls_integer,              -- the empty cell just before it, where a placed block goes
    prev_y pls_integer,
    prev_z pls_integer,
    face   pls_integer := 255);      -- face entered: 0 −x, 1 +x, 2 −y, 3 +y, 4 −z, 5 +z

  -- Reads the player and physics settings (Section 14.3).
  procedure init;

  -- Loads the player from PC_PLAYER. A first visit creates the row, standing on the surface in the middle
  -- of the world, and a player last seen in another world starts there too. Does not commit.
  procedure load(p_player_id in pls_integer, p_world_id in pls_integer);

  -- Puts the player at a position, at rest. Used by load, and by tests.
  procedure place(
    p_px    in binary_double,
    p_py    in binary_double,
    p_pz    in binary_double,
    p_yaw   in binary_double default 0,
    p_pitch in binary_double default 0);

  -- Writes the player back to PC_PLAYER. Does not commit.
  procedure save;

  -- Mouse look (Section 10.2): mouse movement in pixels since the last tick.
  procedure look(p_mdx in pls_integer, p_mdy in pls_integer);

  -- Physics for one tick (Sections 10.3 to 10.6). p_keys is the bitmask of Section 10.1. p_dt is the time
  -- to simulate in seconds; null measures the time since the last call.
  procedure step(p_keys in pls_integer, p_dt in binary_double);

  -- The first solid block along the crosshair within REACH, from the eye (Section 11.1).
  function raycast return t_hit;

  -- Breaks the block under the crosshair (Section 11.2). True when the world changed.
  function break_block return boolean;

  -- Places p_held in front of the block under the crosshair (Section 11.3). True when the world changed.
  function place_block(p_held in pls_integer) return boolean;

end pc_phys;
/
