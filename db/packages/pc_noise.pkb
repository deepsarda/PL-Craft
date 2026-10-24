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
    l_s := mod(nvl(p_seed, 1), pc_const.c_prng_m);
    if l_s<=0 then
      l_s :=1;
    end if;

    for i in 0..255 loop
      l_p(i) := i;
    end loop;

    for i in reverse 0..255 loop
      l_s := MOD(pc_const.c_prng_a * l_s, pc_const.c_prng_m);
      l_j := MOD(l_s, i + 1);
      l_tmp  := l_p(i);
      l_p(i) := l_p(l_j);
      l_p(l_j) := l_tmp;
    end loop;

    for i in 0..511 loop
      g_perm(i) := l_p(mod(i,256));
    end loop;
  end seed;

  function noise2(p_x in binary_double, p_y in binary_double) return binary_double 
  is
  l_s binary_double;
    l_t binary_double;
    l_i simple_integer := 0;
    l_j simple_integer := 0;
    l_ii simple_integer := 0;
    l_jj simple_integer := 0;

    l_x0 binary_double;
    l_y0 binary_double;
    l_z0 binary_double;

    l_i1 simple_integer := 0;
    l_j1 simple_integer := 0;
    l_i2 simple_integer := 0;
    l_j2 simple_integer := 0;

    l_x1 binary_double;
    l_y1 binary_double;
    l_x2 binary_double;
    l_y2 binary_double;


    l_g0 simple_integer := 0;
    l_g1 simple_integer := 0;
    l_g2 simple_integer := 0;

    l_t0 binary_double;
    l_t1 binary_double;
    l_t2 binary_double;
    l_n0 binary_double := 0.0d;
    l_n1 binary_double := 0.0d;
    l_n2 binary_double := 0.0d;
  begin
    l_s := (p_x + p_y) * pc_const.c_f2;
    l_i := floor(p_x + l_s);
    l_j := floor(p_y + l_s);

    l_t := (l_i + l_j) * pc_const.c_g2;
    l_x0 := p_x - (l_i - l_t);
    l_y0 := p_y - (l_j - l_t);

    if l_x0 > l_y0 then
      l_i1 := 1; l_j1 := 0;
    else
      l_i1 := 0; l_j1 := 1;
    end if;

    l_x1 := l_x0 - l_i1 + pc_const.c_g2;
    l_y1 := l_y0 - l_j1 + pc_const.c_g2;
    l_x2 := l_x0 - 1.0d + 2.0d * pc_const.c_g2;
    l_y2 := l_y0 - 1.0d + 2.0d * pc_const.c_g2;

    l_ii := BITAND(l_i, 255);
    l_jj := BITAND(l_j, 255);
    l_g0 := MOD(g_perm(l_ii + g_perm(l_jj)), 8);
    l_g1 := MOD(g_perm(l_ii + l_i1 + g_perm(l_jj + l_j1)), 8);
    l_g2 := MOD(g_perm(l_ii + 1 + g_perm(l_jj + 1)), 8);


    l_t0 := 0.5d - l_x0 * l_x0 - l_y0 * l_y0;
    if l_t0 > 0.0d then
      l_t0 := l_t0 * l_t0;
      l_n0 := l_t0 * l_t0 * grad2(l_g0, l_x0, l_y0);
    end if;
    l_t1 := 0.5d - l_x1 * l_x1 - l_y1 * l_y1;
    if l_t1 > 0.0d then
      l_t1 := l_t1 * l_t1;
      l_n1 := l_t1 * l_t1 * grad2(l_g1, l_x1, l_y1);
    end if;
    l_t2 := 0.5d - l_x2 * l_x2 - l_y2 * l_y2;
    if l_t2 > 0.0d then
      l_t2 := l_t2 * l_t2;
      l_n2 := l_t2 * l_t2 * grad2(l_g2, l_x2, l_y2);
    end if;

    return 70.0d * (l_n0 + l_n1 + l_n2);
  end noise2;

  function noise3(p_x in binary_double, p_y in binary_double, p_z in binary_double) return binary_double 
  is
    l_s binary_double;
    l_t binary_double;
    l_i simple_integer := 0;
    l_j simple_integer := 0;
    l_k simple_integer := 0;
    l_ii simple_integer := 0;
    l_jj simple_integer := 0;
    l_kk simple_integer := 0;

    l_x0 binary_double;
    l_y0 binary_double;
    l_z0 binary_double;

    l_i1 simple_integer := 0;
    l_j1 simple_integer := 0;
    l_k1 simple_integer := 0;
    l_i2 simple_integer := 0;
    l_j2 simple_integer := 0;
    l_k2 simple_integer := 0;

    l_x1 binary_double;
    l_y1 binary_double;
    l_z1 binary_double;
    l_x2 binary_double;
    l_y2 binary_double;
    l_z2 binary_double;
    l_x3 binary_double;
    l_y3 binary_double;
    l_z3 binary_double;

    l_g0 simple_integer := 0;
    l_g1 simple_integer := 0;
    l_g2 simple_integer := 0;
    l_g3 simple_integer := 0;

    l_t0 binary_double;
    l_t1 binary_double;
    l_t2 binary_double;
    l_t3 binary_double;
    l_n0 binary_double := 0.0d;
    l_n1 binary_double := 0.0d;
    l_n2 binary_double := 0.0d;
    l_n3 binary_double := 0.0d; 

  begin
    l_s := (p_x + p_y + p_z) * pc_const.c_f3;
    l_i := floor(p_x + l_s);
    l_j := floor(p_y + l_s);
    l_k := floor(p_z + l_s);

    l_t := (l_i + l_j + l_k) * pc_const.c_g3;
    l_x0 := p_x - (l_i - l_t);
    l_y0 := p_y - (l_j - l_t);
    l_z0 := p_z - (l_k - l_t);

    if l_x0 >=l_y0 then
      if l_y0>=l_z0 then
        l_i1 := 1; l_j1 := 0; l_k1 := 0;
        l_i2 := 1; l_j2 := 1; l_k2 := 0;
      elsif l_x0>=l_z0 then
        l_i1 := 1; l_j1 := 0; l_k1 := 0;
        l_i2 := 1; l_j2 := 0; l_k2 := 1;
      else
        l_i1 := 0; l_j1 := 0; l_k1 := 1;
        l_i2 := 1; l_j2 := 0; l_k2 := 1;
      end if;
    else
      if l_y0 < l_z0 then
        l_i1 := 0; l_j1 := 0; l_k1 := 1;
        l_i2 := 0; l_j2 := 1; l_k2 := 1;
      elsif l_x0 < l_z0 then
        l_i1 := 0; l_j1 := 1; l_k1 := 0;
        l_i2 := 0; l_j2 := 1; l_k2 := 1;
      else
        l_i1 := 0; l_j1 := 1; l_k1 := 0;
        l_i2 := 1; l_j2 := 1; l_k2 := 0;
      end if;
    end if;

    l_x1 := l_x0 - l_i1 + pc_const.c_g3;
    l_y1 := l_y0 - l_j1 + pc_const.c_g3;
    l_z1 := l_z0 - l_k1 + pc_const.c_g3;
    l_x2 := l_x0 - l_i2 + 2.0d * pc_const.c_g3;
    l_y2 := l_y0 - l_j2 + 2.0d * pc_const.c_g3;
    l_z2 := l_z0 - l_k2 + 2.0d * pc_const.c_g3;
    l_x3 := l_x0 - 1.0d + 3.0d * pc_const.c_g3;
    l_y3 := l_y0 - 1.0d + 3.0d * pc_const.c_g3;
    l_z3 := l_z0 - 1.0d + 3.0d * pc_const.c_g3;

    l_ii := BITAND(l_i, 255);
    l_jj := BITAND(l_j, 255);
    l_kk := BITAND(l_k, 255);
    l_g0 := MOD(g_perm(l_ii + g_perm(l_jj + g_perm(l_kk))), 12);
    l_g1 := MOD(g_perm(l_ii + l_i1 + g_perm(l_jj + l_j1 + g_perm(l_kk + l_k1))), 12);
    l_g2 := MOD(g_perm(l_ii + l_i2 + g_perm(l_jj + l_j2 + g_perm(l_kk + l_k2))), 12);
    l_g3 := MOD(g_perm(l_ii + 1 + g_perm(l_jj + 1 + g_perm(l_kk + 1))), 12);
    
    l_t0 := 0.5d - l_x0 * l_x0 - l_y0 * l_y0 - l_z0 * l_z0;
    if l_t0 > 0.0d then
      l_t0 := l_t0 * l_t0;
      l_n0 := l_t0 * l_t0 * grad3(l_g0, l_x0, l_y0, l_z0);
    end if;
    l_t1 := 0.5d - l_x1 * l_x1 - l_y1 * l_y1 - l_z1 * l_z1;
    if l_t1 > 0.0d then
      l_t1 := l_t1 * l_t1;
      l_n1 := l_t1 * l_t1 * grad3(l_g1, l_x1, l_y1, l_z1);
    end if;
    l_t2 := 0.5d - l_x2 * l_x2 - l_y2 * l_y2 - l_z2 * l_z2;
    if l_t2 > 0.0d then
      l_t2 := l_t2 * l_t2;
      l_n2 := l_t2 * l_t2 * grad3(l_g2, l_x2, l_y2, l_z2);
    end if;
    l_t3 := 0.5d - l_x3 * l_x3 - l_y3 * l_y3 - l_z3 * l_z3;
    if l_t3 > 0.0d then
      l_t3 := l_t3 * l_t3;
      l_n3 := l_t3 * l_t3 * grad3(l_g3, l_x3, l_y3, l_z3);
    end if;
    return 32.0d * (l_n0 + l_n1 + l_n2 + l_n3);
  end noise3;

  function fbm2(
    p_x          in binary_double,
    p_y          in binary_double,
    p_octaves    in pls_integer,
    p_lacunarity in binary_double,
    p_gain       in binary_double) return binary_double
  is
    l_sum_noise  BINARY_DOUBLE  := 0.0d;
    l_sum_weight BINARY_DOUBLE  := 0.0d;
    l_cur_weight BINARY_DOUBLE  := 1.0d;
    l_cur_freq   BINARY_DOUBLE  := 1.0d;
    l_octaves    SIMPLE_INTEGER := NVL(p_octaves, 4);
  begin
      for o in 0 .. l_octaves - 1 loop
      l_sum_noise  := l_sum_noise + l_cur_weight * noise2(p_x * l_cur_freq, p_y * l_cur_freq);
      l_sum_weight := l_sum_weight + l_cur_weight;
      l_cur_weight := l_cur_weight * p_gain;
      l_cur_freq   := l_cur_freq * p_lacunarity;
    end loop;
    if l_sum_weight > 0.0d then
      return l_sum_noise / l_sum_weight;
    else
      return 0.0d;
    end if;
  end fbm2;

end pc_noise;
/
