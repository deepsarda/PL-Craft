create or replace package body pc_noise as

  type t_perm_array is table of pls_integer index by pls_integer;
  g_perm t_perm_array;

   function grad2(
    p_gi in simple_integer,
    p_x  in binary_double,
    p_y  in binary_double
  ) return binary_double
  is
  begin
    case p_gi
      when 0 then return  p_x + p_y;
      when 1 then return -p_x + p_y;
      when 2 then return  p_x - p_y;
      when 3 then return -p_x - p_y;
      when 4 then return  p_x;
      when 5 then return -p_x;
      when 6 then return  p_y;
      when 7 then return -p_y;
      else        return 0.0d;
    end case;
  end grad2;

  function grad3(
    p_gi in simple_integer,
    p_x  in binary_double,
    p_y  in binary_double,
    p_z  in binary_double
  ) return binary_double
  is
  begin
    case p_gi
      when 0 then return  p_x + p_y;
      when 1 then return -p_x + p_y;
      when 2 then return  p_x - p_y;
      when 3 then return -p_x - p_y;
      when 4 then return  p_x + p_z;
      when 5 then return -p_x + p_z;
      when 6 then return  p_x - p_z;
      when 7 then return -p_x - p_z;
      when 8 then return  p_y + p_z;
      when 9 then return -p_y + p_z;
      when 10 then return  p_y - p_z;
      when 11 then return -p_y - p_z;
      else        return 0.0d;
    end case;
  end grad3;

  procedure seed(p_seed in pls_integer)
   is
    l_s number;
    l_p t_perm_array;
    l_j simple_integer := 0;
    l_tmp pls_integer;
  begin 
    l_s := mod(nvl(p_seed, 1), c_prng_m);
    if l_s<=0 then
      l_s :=1;
    end if;

    for i in 0..255 loop
      l_p(i) := i;
    end loop;

    for i in reverse 0..255 loop
      l_s := MOD(c_prng_a * l_s, c_prng_m);
      l_j := MOD(l_s, i + 1);
      l_tmp  := l_p(i);
      l_p(i) := l_p(l_j);
      l_p(l_j) := l_tmp;
    end loop;

    for i in 0..511 loop
      g_perm(i) := l_p(mod(i,256));
    end loop;
  end seed;

  function noise2(p_x in binary_double, p_y in binary_double) return binary_double is
  begin
    return 0d;
  end noise2;

  function noise3(p_x in binary_double, p_y in binary_double, p_z in binary_double) return binary_double is
  begin
    return 0d;
  end noise3;

  function fbm2(
    p_x          in binary_double,
    p_y          in binary_double,
    p_octaves    in pls_integer,
    p_lacunarity in binary_double,
    p_gain       in binary_double) return binary_double
  is
  begin
    return 0d;
  end fbm2;

end pc_noise;
/
