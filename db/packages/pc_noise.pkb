create or replace package body pc_noise as

  -- STUB until Section 6 is built: no permutation table, and every function returns 0. Tests T-N1 to T-N4
  -- (Section 15) define done: same seed same world, output ranges near ±1, and smoothness.

  procedure seed(p_seed in pls_integer) is
  begin
    null;
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
