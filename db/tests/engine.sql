-- A whole tick (Sections 3.2 and 11.4). Same conventions as physics.sql. It loads world 1 as player 1, so
-- it needs a generated world 1; it writes nothing beyond the row of a player seen for the first time.

-- T-R1 through a whole tick: init_session and one tick give a v1 frame in which every column covers every row
declare
  l_frame  blob;
  l_at     pls_integer := 53;
  l_width  pls_integer;
  l_height pls_integer;
  l_runs   pls_integer;
  l_rows   pls_integer;
  l_total  pls_integer := 0;

  function u(p_at in pls_integer, p_bytes in pls_integer) return pls_integer is
  begin
    return to_number(rawtohex(dbms_lob.substr(l_frame, p_bytes, p_at)), 'XXXXXXXX');
  end u;
begin
  pc_engine.init_session(1, 1);
  pc_engine.tick(7, 0, 0, 0, 0, 0, pc_const.c_stone, 1 / 24, l_frame);
  if rawtohex(dbms_lob.substr(l_frame, 3, 1)) != '504301' or u(5, 4) != 7 then
    raise_application_error(-20000, 'not a version 1 frame answering seq 7');
  end if;
  l_width := u(9, 2);
  l_height := u(11, 2);
  for c in 1 .. l_width loop
    l_runs := u(l_at, 2);
    l_at := l_at + 2;
    l_rows := 0;
    for k in 1 .. l_runs loop
      l_rows := l_rows + u(l_at + 2, 2);
      l_at := l_at + 5;
    end loop;
    if l_rows != l_height then
      raise_application_error(-20000, 'column ' || c || ' covers ' || l_rows || ' of ' || l_height || ' rows');
    end if;
    l_total := l_total + l_runs;
  end loop;
  if l_at - 1 != dbms_lob.getlength(l_frame) or l_total != u(49, 4) then
    raise_application_error(-20000, 'length or run_total does not match the columns');
  end if;
end;
/
