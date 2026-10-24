create or replace package body pc_frame as

  -- Section 9.2, with one change: run only records three numbers and finish does all the hex work. The
  -- renderer's loop stays short, and pack_us then measures exactly what B5 budgets.
  -- If B5 misses its 5 ms, the doc's fallback is returning RAW(32767) chunks instead of a BLOB.

  c_flush_at constant simple_integer := 32000; -- hex characters: HEXTORAW then stays inside RAW's 32,767 bytes

  type t_ints is table of pls_integer index by pls_integer;
  type t_hex4 is table of varchar2(4) index by pls_integer;

  g_width  pls_integer;
  g_height pls_integer;
  g_blob   blob;                   -- one session-long temporary BLOB, trimmed and refilled every frame
  g_hex1   pc_const.t_hex;         -- 0..255 → '00'..'FF'
  g_hex4   t_hex4;                 -- 0..65535 → '0000'..'FFFF': rows, lengths and counts without division
  g_start  t_ints;                 -- this frame's runs, column after column
  g_length t_ints;
  g_index  t_ints;
  g_runs   simple_integer := 0;
  g_ends   t_ints;                 -- g_ends(c): runs recorded up to the end of column c
  g_cols   simple_integer := 0;

  -- Big-endian hex of an unsigned value, clamped to what p_bytes can hold. For the header only.
  function hex(p_value in number, p_bytes in pls_integer) return varchar2 is
    l_value number := greatest(0, least(power(256, p_bytes) - 1, round(p_value)));
    l_hex   varchar2(8);
  begin
    for i in 1 .. p_bytes loop
      l_hex := g_hex1(mod(l_value, 256)) || l_hex;
      l_value := trunc(l_value / 256);
    end loop;
    return l_hex;
  end hex;

  procedure init(p_width in pls_integer, p_height in pls_integer) is
  begin
    g_width := p_width;
    g_height := p_height;
    if g_hex4.count = 0 then
      g_hex1 := pc_const.g_hex;
      for i in 0 .. 65535 loop
        g_hex4(i) := g_hex1(trunc(i / 256)) || g_hex1(mod(i, 256));
      end loop;
    end if;
    if g_blob is null then
      dbms_lob.createtemporary(g_blob, cache => true, dur => dbms_lob.session);
    end if;
  end init;

  procedure begin_frame is
  begin
    g_runs := 0;
    g_cols := 0;
  end begin_frame;

  procedure run(p_start in pls_integer, p_length in pls_integer, p_index in pls_integer) is
  begin
    g_runs := g_runs + 1;
    g_start(g_runs) := p_start;
    g_length(g_runs) := p_length;
    g_index(g_runs) := p_index;
  end run;

  procedure end_column is
  begin
    g_cols := g_cols + 1;
    g_ends(g_cols) := g_runs;
  end end_column;

  procedure finish(p_header in t_header, p_frame out blob) is
    l_began  timestamp(6) with time zone := systimestamp;
    l_buffer varchar2(32767) := rpad('0', 104, '0'); -- 52 zero bytes; the header is written last
    l_column varchar2(32767);
    l_first  simple_integer := 1;
  begin
    dbms_lob.trim(g_blob, 0);
    for c in 1 .. g_cols loop
      -- The run count leads the column, so each column is staged before it joins the buffer.
      l_column := g_hex4(g_ends(c) - l_first + 1);
      for k in l_first .. g_ends(c) loop
        l_column := l_column || g_hex4(g_start(k)) || g_hex4(g_length(k)) || g_hex1(g_index(k));
      end loop;
      if length(l_buffer) + length(l_column) > c_flush_at then
        dbms_lob.writeappend(g_blob, length(l_buffer) / 2, hextoraw(l_buffer));
        l_buffer := null;
      end if;
      l_buffer := l_buffer || l_column;
      l_first := g_ends(c) + 1;
    end loop;
    dbms_lob.writeappend(g_blob, length(l_buffer) / 2, hextoraw(l_buffer));

    -- The header goes last because it carries pack_us (Section 9.2).
    dbms_lob.write(g_blob, 52, 1, hextoraw(
         '5043' || '01'                                    -- magic "PC", version 1
      || hex(p_header.flags, 1) || hex(p_header.seq, 4) || hex(g_width, 2) || hex(g_height, 2)
      || hex(p_header.render_us, 4) || hex(p_header.phys_us, 2) || hex(p_header.edit_us, 2)
      || hex(pc_const.seconds_since(l_began) * 1e6, 2)     -- pack_us
      || '0000'
      || hex(p_header.px * 1000, 4) || hex(p_header.py * 1000, 4) || hex(p_header.pz * 1000, 4)
      || hex(p_header.yaw * 1e4, 2) || hex(p_header.pitch * 1e4 + 32768, 2)
      || hex(p_header.held, 1) || hex(p_header.target_face, 1)
      || hex(p_header.target_x, 2) || hex(p_header.target_y, 2) || hex(p_header.target_z, 2)
      || hex(g_runs, 4)));
    p_frame := g_blob;
  end finish;

  procedure free is
  begin
    if g_blob is not null then
      dbms_lob.freetemporary(g_blob);
      g_blob := null;
    end if;
  end free;

end pc_frame;
/
