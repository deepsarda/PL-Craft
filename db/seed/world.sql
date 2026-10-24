-- A first install gets world 1 with seed 1337, the seed the golden-frame tests use (Section 15).
-- Later installs find a world and leave everything as it is.
declare
  l_worlds pls_integer;
begin
  select count(*) into l_worlds from pc_worlds;
  if l_worlds = 0 then
    pc_world.generate(1, 1337);
  end if;
end;
/
