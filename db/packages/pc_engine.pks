-- The only package called from outside (Section 3.2). Node calls it on each player's own connection,
-- so package state (world, player, frame BLOB) carries over from one tick to the next.
create or replace package pc_engine as

  -- Loads the world and the player, reads PC_CONFIG and creates the reused frame BLOB.
  procedure init_session(
    p_world_id      in pls_integer,
    p_player_id     in pls_integer,
    p_debug_heatmap in boolean default false);

  -- One tick in the order of Section 11.4. Input fields as in Section 10.1; p_dt is NULL in play and
  -- fixed (usually 1/24) in tests and replays. Returns a frame in the format of Section 9.1.
  procedure tick(
    p_seq    in pls_integer,
    p_keys   in pls_integer,
    p_mdx    in pls_integer,
    p_mdy    in pls_integer,
    p_lclick in pls_integer,
    p_rclick in pls_integer,
    p_held   in pls_integer,
    p_dt     in binary_double,
    p_frame  out blob);

  -- Saves the player, commits and frees the frame BLOB.
  procedure shutdown;

end pc_engine;
/
