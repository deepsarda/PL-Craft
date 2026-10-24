-- Seeded randomness and simplex noise for terrain (Section 6). Engine lane.
create or replace package pc_noise as

  -- Builds the permutation table from the seed: Park–Miller draws and a Fisher–Yates shuffle (6.1).
  procedure seed(p_seed in pls_integer);

  -- 2D simplex noise, roughly −1 to 1 (6.2).
  function noise2(p_x in binary_double, p_y in binary_double) return binary_double;

  -- 3D simplex noise, roughly −1 to 1 (6.3).
  function noise3(p_x in binary_double, p_y in binary_double, p_z in binary_double) return binary_double;

  -- Fractal Brownian motion of noise2, divided by the total weight so it stays within −1 to 1 (6.4).
  function fbm2(
    p_x          in binary_double,
    p_y          in binary_double,
    p_octaves    in pls_integer,
    p_lacunarity in binary_double,
    p_gain       in binary_double) return binary_double;

end pc_noise;
/
