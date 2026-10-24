create or replace package body pc_const as

  function setting(p_name in varchar2) return number is
    l_value number;
  begin
    select value into l_value from pc_config where name = p_name;
    return l_value;
  exception
    when no_data_found then
      raise_application_error(-20100, 'PC_CONFIG has no ' || p_name || '. Run npm run db:install to add the defaults.');
  end setting;

  function seconds_since(p_start in timestamp with time zone) return binary_double is
    l_took interval day(9) to second(6) := systimestamp - p_start;
  begin
    return extract(day from l_took) * 86400 + extract(hour from l_took) * 3600
         + extract(minute from l_took) * 60 + extract(second from l_took);
  end seconds_since;

  function placeable(p_m in pls_integer) return boolean is
  begin
    return p_m is not null
       and p_m in (c_stone, c_dirt, c_grass, c_sand, c_log, c_leaves, c_planks, c_cobblestone, c_brick, c_snow);
  end placeable;

begin
  for i in 0 .. 255 loop
    g_hex(i) := to_char(i, 'fm0X');
  end loop;
end pc_const;
/
