-- Frame packing (Section 9). The renderer hands over runs column by column; finish packs them and the
-- 52-byte header into one session-long BLOB in the format of Section 9.1.
create or replace package pc_frame as

  -- The header fields the caller knows. finish adds magic, version, width, height, pack_us and run_total.
  type t_header is record (
    flags       pls_integer := 0,  -- bit 0 target valid, bit 1 world edited this tick, bit 2 heat map
    seq         pls_integer := 0,
    render_us   pls_integer := 0,
    phys_us     pls_integer := 0,
    edit_us     pls_integer := 0,
    px          binary_double := 0,
    py          binary_double := 0,
    pz          binary_double := 0,
    yaw         binary_double := 0,
    pitch       binary_double := 0,
    held        pls_integer := 0,
    target_face pls_integer := 255, -- 0 −x, 1 +x, 2 −y, 3 +y, 4 −z, 5 +z, 255 none
    target_x    pls_integer := 0,
    target_y    pls_integer := 0,
    target_z    pls_integer := 0);

  -- Remembers the screen size and creates the session's BLOB. Once per session.
  procedure init(p_width in pls_integer, p_height in pls_integer);

  -- Starts a frame, forgetting the previous frame's runs.
  procedure begin_frame;

  -- One run in the current column: p_length rows from row p_start in palette index p_index.
  -- Runs may come in paint order rather than row order.
  procedure run(p_start in pls_integer, p_length in pls_integer, p_index in pls_integer);

  -- Closes the current column. Once per screen column, left to right.
  procedure end_column;

  -- Packs every run and the header into the BLOB and returns it. pack_us is the time spent here: hex text,
  -- HEXTORAW and the BLOB writes, which is what benchmark B5 budgets at 5 ms.
  procedure finish(p_header in t_header, p_frame out blob);

  -- Frees the BLOB at the end of the session.
  procedure free;

end pc_frame;
/
