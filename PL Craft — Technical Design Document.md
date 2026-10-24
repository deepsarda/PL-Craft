# PL/Craft — Technical Design Document

Oct 23, 2026 · @Deep

## 1. Overview

**PL/Craft** (working title) is a Minecraft-style voxel game where **the whole game runs inside Oracle as PL/SQL**: world generation, physics, block editing and rendering. The browser is a dumb terminal. It sends keys and mouse movement, and draws the frame the database sends back.

**Target:** 640×360 pixels at **24 frames per second (fps)**, on Oracle AI Database Free.

> **The one idea this design rests on.** Doom-style engines are fast because they cast **one ray per screen column**, not one per pixel. We do the same. Each world column stores a short list of solid **spans**, so arches and overhangs still work. Section 8 has the details.

### Goals

| ID | Goal | Done when |
| --- | --- | --- |
| G1 | **Terrain** from 2D simplex noise | A seed always produces the same world |
| G2 | **Arches and overhangs** from 3D noise | A column can hold more than one solid span |
| G3 | **First-person movement** with gravity, jumping and collision | You cannot walk or fall through blocks |
| G4 | **Break and place blocks** with the mouse | The change shows in the very next frame |
| G5 | **Every pixel decided by PL/SQL** | The browser only expands runs and applies a palette |
| G6 | **World saved in tables** | Restarting the database loses nothing |

### Non-goals for v1

These are out of scope on purpose. Each one either breaks the column renderer or blows the time budget.

- **Textures** on block faces. They break run-length output (Section 9).
- **Transparency**: glass, see-through water, leaves.
- **Sprites and mobs**: anything that is not a block.
- **Light propagation**: torches, caves going dark.
- **Looking straight up or down.** Pitch is limited to about ±35° (Section 7).
- **Multiplayer** and **infinite worlds**.

### Success criteria

| Measure | Target | How we measure it |
| --- | --- | --- |
| Render + packing time per frame | **≤ 25 ms** at the 95th percentile | `render_us` plus pack\_us, from the frame header |
| End-to-end frame time | **≤ 41.7 ms** (that is, 24 fps) | Browser heads-up display (HUD) |
| World load on session start | **≤ 3 s** | Timing of `engine.init_session` |
| Pixel coverage | **Every pixel written exactly once** per frame | Unit test on the renderer |

> **Fallback.** If the Milestone 0 benchmarks (Section 4) miss the budget, we drop to **320×180**. That halves the column count, and so roughly halves the render cost. Nothing else in this design changes.

## 2. Glossary

Read this first if you are new to the project. Every term below is used later without being explained again.

### World and rendering terms

| Term | Meaning | Example |
| --- | --- | --- |
| **Block** (voxel) | A 1×1×1 cube of the world. Stored as a **material id** from 0 to 15. **0 means air.** | Block (10, 23, 40) = 2 (grass) |
| **World column** | All blocks at one (x, z) position, from y = 0 to y = 63. | Column (10, 40) holds 64 blocks |
| **Screen column** | One vertical line of pixels on screen, numbered c = 0 to 639. | c = 320 is the middle of the screen |
| **Span** | A **vertical run of the same solid material** inside one world column. Written \[y0, y1): bottom included, top excluded. | Stone \[0, 20), dirt \[20, 23), grass \[23, 24) |
| **Span cache** | The list of spans for every world column. Rebuilt from blocks whenever a column changes. | 3 spans for flat grassland |
| **DDA** (Digital Differential Analyzer) | An algorithm that walks a grid along a ray and **visits every cell the ray passes through, in order**. We use the Amanatides–Woo version. | Ray from (5.5, 5.5) heading east visits cells (5,5), (6,5), (7,5)… |
| **Perpendicular depth** (t) | Distance measured **along the camera's forward axis**, not along the ray. Using it removes the fisheye effect. | A wall straight ahead and one at the screen edge, both 10 units forward, both have t = 10 |
| **Focal length** (f) | How many pixels one world unit covers at depth 1. f = (screen width ÷ 2) ÷ tan(horizontal FOV ÷ 2). | f = 320 at 640 wide and a 90° FOV |
| **FOV** (field of view) | The angle the screen covers. | 90° horizontal, about 58.7° vertical at 640×360 |
| **Horizon row** (h) | The screen row where things **at eye height** appear. | h = 180 when looking level |
| **Y-shearing** | Faking up/down look by **moving the horizon row** instead of rotating the camera. | Looking up 35° moves h from 180 to 404 |
| **Coverage list** | For one screen column, the list of **rows not yet painted**. The renderer only paints into these. | Starts as \[0, 359\]; ends empty |
| **Run** | A stretch of rows in one screen column with **one colour**. Written (start row, length, palette index). | (200, 40, 37) = rows 200–239 in colour 37 |
| **Palette index** | One byte that picks a colour. **index = material × 16 + brightness level.** | Grass (2), brightness 5 → index 37 |

### Terrain terms

| Term | Meaning | Example |
| --- | --- | --- |
| **Simplex noise** | Ken Perlin's smooth random function, built on triangles (2D) or tetrahedra (3D). Gives values in about **−1 to 1**. | noise2(10.3, 4.7) = 0.42 |
| **Octave** | One layer of noise at a given frequency. | Octave 0 = big hills, octave 3 = small bumps |
| **fBm** (fractal Brownian motion) | Adding octaves together, each at **double the frequency and half the strength** of the last. | 4 octaves → hills with bumps on them |
| **Density field** | A 3D function. A block is solid **where density > 0**. Gives caves, overhangs and arches. | density(x, y, z) = noise3(…) + (height − y) ÷ 8 |

### Oracle and PL/SQL terms

| Term | Meaning | Why it matters here |
| --- | --- | --- |
| **Package state** | The values of **package-level variables**. Each database session has its own copy. | The whole world and player live here while playing |
| **PGA** (Program Global Area) | The per-session memory where package state is kept. | Our world must fit here (Section 5) |
| **Native compilation** | `PLSQL_CODE_TYPE = NATIVE` compiles PL/SQL to **machine code** instead of interpreted bytecode. | Required for speed |
| **SIMPLE\_INTEGER** | A 32-bit integer type that is **never null and skips overflow checks**. | Fastest integer type in native mode |
| **BINARY\_DOUBLE** | A 64-bit **hardware float** (IEEE 754). | Fast maths. Never use `NUMBER` in hot loops: it is slow software decimal maths |
| **ORDS** (Oracle REST Data Services) | Oracle's built-in web layer. | We **do not use it** for the game loop (Section 12) |

### Other terms

| Term | Meaning |
| --- | --- |
| **Tick** | One server update: apply input, run physics, handle clicks, render, return a frame. One tick per frame. |
| **AABB** (axis-aligned bounding box) | The player's collision box: 0.6 × 1.8 × 0.6 blocks. |
| **WebSocket** (WS) | A two-way browser connection that stays open. Carries inputs up and frames down. |
| **HUD** (heads-up display) | Text drawn over the game: fps, render time, position. |
| **p95** | 95th percentile. 95% of frames are at or below this time. |

## 3. System architecture

Three tiers: a **browser** that captures input and shows frames, a thin **Node.js relay**, and **Oracle**, where all game logic lives. Each player gets **one dedicated database session**, and their world lives in that session's package state for as long as they play.

&#91;embedded content: System architecture · 3 tiers, 6 packages shown\]

Read it left to right: input travels right as a \~100-byte JSON message, and a \~76 KB frame travels back. Inside Oracle, only `pc_engine` is called from outside; it drives the other five packages, which share the session's package state.

### 3.1 What happens in one frame

1. The **browser** sends the latest input over the WebSocket (Section 10.1).
2. **Node** calls `pc_engine.tick` on that player's own connection (Section 12.2).
3. **`pc_phys`** applies mouse look and physics, then aims a ray from the crosshair (Sections 10 and 11).
4. On a click, **`pc_world`** changes one block, rebuilds that column's spans and saves the row (Section 11).
5. **`pc_render`** walks all 640 screen columns and emits runs (Section 8).
6. **`pc_frame`** packs the runs and header into the reused BLOB (Section 9.2).
7. **Node** forwards the bytes. The **browser** expands runs, applies the palette, draws, and sends the next input (Sections 9.3 and 12.3).

### 3.2 Public API

These are the only entry points the middleware and admin scripts call. Everything else is internal.

| Procedure | Parameters | What it does | Called by |
| --- | --- | --- | --- |
| `pc_world.generate` | `p_world_id`, `p_seed` | Generates terrain (Section 6), writes `PC_WORLD` and all 16,384 `PC_COLUMN` rows | Admin script, once per world |
| `pc_engine.init_session` | `p_world_id`, `p_player_id`, `p_debug_heatmap` | Loads blocks, builds spans, loads the player, creates the BLOB and hex table, reads `PC_CONFIG` | Node, on connect |
| `pc_engine.tick` | IN: `p_seq`, `p_keys`, `p_mdx`, `p_mdy`, `p_lclick`, `p_rclick`, `p_held`, `p_dt` (NULL in play). OUT: `p_frame` (BLOB) | Runs one tick in the order of Section 11.4 and returns the frame | Node, once per input |
| `pc_engine.shutdown` | none | Saves the player, commits, frees the temporary BLOB | Node, on disconnect |

## 4. Performance budget and benchmarks

At 24 fps every frame gets **41.7 ms** from key press to pixels. The renderer gets **about 20 ms** of that. **Nothing else gets built until Milestone 0 proves PL/SQL can hit these numbers**, because every number in this section is an estimate.

> **Hard limits of Oracle AI Database Free.** It uses at most **2 CPU cores** and **2 GB of RAM**, stores at most **12 GB of user data**, and allows **one installation per machine or container** ([Oracle docs](https://docs.oracle.com/en/database/oracle/oracle-database/23/xeinl/licensing-restrictions.html)). One player's tick runs on one core, so the second core is spare.

### Where the 41.7 ms goes

| Stage | Runs in | Budget (ms) | Measured by |
| --- | --- | --- | --- |
| Capture input, send over WebSocket | Browser | 1 | Browser timestamps |
| Node → Oracle call and return | Node + Oracle | 2 | Node timer around the call |
| Mouse look and physics | PL/SQL | 1 | `phys_us` in frame header |
| Block break / place (only on click frames) | PL/SQL | 0.5 | `edit_us` in frame header |
| **Column renderer** | PL/SQL | **20** | `render_us` in frame header |
| **Packing runs into the frame BLOB** | PL/SQL | **5** | `pack_us` in frame header |
| Node → browser | Node | 1 | Browser timestamps |
| Expand runs, apply palette, draw | Browser | 2 | `performance.now()` |
| **Slack** for spikes | — | **9.2** | — |
| **Total** |  | **41.7** | Browser HUD |

### How much work one frame is

The renderer walks the world grid once per screen column (Section 8). With a **90° field of view** and a **view distance of 48 blocks**, a simulation of the march gives **about 71 grid cells per column on average, 98 at worst**. Edge columns walk further because their rays run diagonally.

- **Cells per frame:** 640 columns × 71 cells ≈ **45,500 cell visits**.
- **Work per cell:** one DDA step (about 10 simple operations), then 1–2 spans checked (about 15 operations each, thanks to the early break in Section 8.6).
- **Total:** roughly **2 million simple operations per frame**, or about **48 million per second** at 24 fps.

> **Honest uncertainty.** We do not know how many simple operations per second natively compiled PL/SQL achieves on this machine. A guess of 50–200 million per second puts us anywhere from "comfortable" to "just misses". That is exactly why Milestone 0 exists.

### Milestone 0: the benchmarks

Run each benchmark **3 times and keep the median**; the first run warms caches. Time with `DBMS_UTILITY.GET_CPU_TIME` (hundredths of a second) for long loops, and with the difference of two `SYSTIMESTAMP` values for short ones. Run everything **twice: once interpreted, once natively compiled**, so we know what native buys us.

| ID | What it measures | Setup | Pass when |
| --- | --- | --- | --- |
| **B1** | Raw loop speed | 10 million iterations of `i := i + 1` with `SIMPLE_INTEGER` | Record nanoseconds per iteration (no pass mark; it calibrates the rest) |
| **B2** | Float maths speed | 10 million iterations of `a := a * b + c`, once with `BINARY_DOUBLE`, once with `NUMBER` | `BINARY_DOUBLE` is clearly faster. Confirms the "never `NUMBER`" rule |
| **B3** | Collection read speed and memory | 10 million random reads from 1 million elements. Try **associative array** (`INDEX BY PLS_INTEGER`), **nested table** (pre-extended) and **VARRAY**. Also read `session pga memory` from `V$MYSTAT` before and after filling | Pick the fastest. Memory for 1 million elements **under 100 MB** |
| **B4** | **Fake frame** | 640 columns × 71 DDA steps. Each step does one collection read and two `BINARY_DOUBLE` projections. No coverage logic | **≤ 15 ms** |
| **B5** | Frame packing | Write 15,000 runs (5 bytes each) as hex text, convert with `HEXTORAW`, append to a **reused temporary BLOB** | **≤ 5 ms** |
| **B6** | Round trip | Node calls a procedure that returns a 75 KB BLOB, 1,000 times in a row | **p95 ≤ 3 ms** |

> Reading `V$MYSTAT` and `V$STATNAME` needs a grant: `GRANT SELECT ON V_$MYSTAT TO <user>` and the same for `V_$STATNAME`, run as a DBA.

### Decision rule after Milestone 0

| B4 + B5 result | Decision |
| --- | --- |
| **≤ 25 ms** | Build at **640×360**, view distance 48. |
| **25–50 ms** | Build at **320×180**. Half the columns means roughly half the render and packing cost. |
| **Over 50 ms** | Stop. Try view distance 32 and 256×144 before writing anything else. |

## 5. World model and data structures

The world is a fixed **128 × 64 × 128** grid of blocks (x × y × z), about **1 million blocks**. While playing, it lives in **two in-memory structures**: a dense block array (the truth) and a span cache (what the renderer reads). Tables only hold the saved copy.

### 5.1 Coordinate system

- **x** runs east, 0 to 127. **z** runs south, 0 to 127. **y** runs up, 0 to 63.
- Block (x, y, z) fills the cube from **(x, y, z) to (x+1, y+1, z+1)**. So the block under a point is found with `FLOOR` on each coordinate.
- **All world coordinates are ≥ 0.** This is deliberate: it lets `MOD` and `TRUNC` behave like `FLOOR` everywhere, and saves us from Oracle's negative-number `MOD` behaviour (`MOD(-1, 256) = -1`, not 255).
- **Yaw** (θ) is the compass direction you face. **θ = 0 faces east (+x)**; θ increases turning toward south (+z).
- **Forward vector:** (cos θ, 0, sin θ). **Right vector:** (−sin θ, 0, cos θ).
- *Check:* facing east (θ = 0), right = (0, 0, 1) = south. Your right hand points south when you face east. ✔
- **Pitch** (φ) is up/down look. **Positive = looking up.** Limited to ±35° (Section 7).

### 5.2 Materials

One byte per block, but only values **0–15** are used, so a material always fits in 4 bits of the palette index (Section 9).

| Id | Name | Solid for physics | Placeable by player | Notes |
| --- | --- | --- | --- | --- |
| 0 | Air | No | — | Never rendered |
| 1 | Bedrock | Yes | No | Layer y = 0. Cannot be broken |
| 2 | Stone | Yes | Yes |  |
| 3 | Dirt | Yes | Yes |  |
| 4 | Grass | Yes | Yes | Top block of land |
| 5 | Sand | Yes | Yes | Beaches near sea level |
| 6 | Water | **Yes in v1** | No | Opaque and walkable in v1 (like ice). Real water needs transparency, a non-goal |
| 7 | Log | Yes | Yes |  |
| 8 | Leaves | Yes | Yes | Opaque in v1 |
| 9 | Planks | Yes | Yes |  |
| 10 | Cobblestone | Yes | Yes |  |
| 11 | Brick | Yes | Yes |  |
| 12 | Snow | Yes | Yes | Top block above y = 44 |
| 13–15 | Reserved | — | — | Free for later |

### 5.3 Dense block array (source of truth)

One collection of **1,048,576 integers**, one per block. The index puts each world column's 64 blocks **next to each other**, because the span builder reads whole columns:

```latex
\text{col}(x, z) = x \cdot 128 + z \qquad \text{idx}(x, y, z) = \text{col}(x, z) \cdot 64 + y
```

*Example:* block (10, 23, 40) → col = 10 × 128 + 40 = **1320** → idx = 1320 × 64 + 23 = **84,503**.

**Out-of-bounds rules.** These keep every caller simple:

| Where | Renderer sees | Physics sees |
| --- | --- | --- |
| x or z outside 0–127 | Nothing: the ray stops | **Solid** (an invisible wall at the world edge) |
| y < 0 | — | **Solid** |
| y ≥ 64 | Air | Air |

**Collection type:** decided by benchmark **B3** (Section 4). Element type `PLS_INTEGER`; loop variables `SIMPLE_INTEGER`.

### 5.4 Span cache (what the renderer reads)

A **span** is a vertical run of one material in one world column, written **\[y0, y1)**: y0 is the lowest block, y1 is one above the highest. Spans are stored **sorted bottom to top**, with at most **16 per column** (`MAX_SPANS`).

Three flat collections with a fixed stride of 16, plus a count:

| Collection | Index | Holds |
| --- | --- | --- |
| `g_span_n` | col | Number of spans in this column (0–16) |
| `g_span_y0` | col × 16 + k | Bottom of span k |
| `g_span_y1` | col × 16 + k | Top of span k (exclusive) |
| `g_span_m` | col × 16 + k | Material of span k |

*Example: plains column with surface at y = 23.*

| k | y0 | y1 | Material |
| --- | --- | --- | --- |
| 0 | 0 | 1 | Bedrock |
| 1 | 1 | 20 | Stone |
| 2 | 20 | 23 | Dirt |
| 3 | 23 | 24 | Grass |

Add an arch of stone at y = 30–32 above it and the column gets a fifth span: **k = 4, \[30, 33), stone**. That is all an arch is to the renderer.

**Building one column's spans** (called on load and after every edit):

1. Set n = 0 and "current material" = air.
2. For y = 0 to 63: read block m.
3. If m differs from the current material: close the open span (if any) at y1 = y. If m is not air, open a new span at y0 = y with material m.
4. After y = 63, close any open span at y1 = 64.
5. **Overflow:** if a 17th span would open, extend the 16th span to the column top instead, keeping its material. Log a warning. Natural terrain should never hit this; it is a guard against players building stripey towers.

### 5.5 Player state

One record in package state:

| Field | Type | Meaning | Example |
| --- | --- | --- | --- |
| `px, py, pz` | `BINARY_DOUBLE` | **Feet** position (centre of the bottom of the box) | (64.5, 24.0, 64.5) |
| `vx, vy, vz` | `BINARY_DOUBLE` | Velocity in blocks per second | (0, −3.2, 0) while falling |
| `yaw, pitch` | `BINARY_DOUBLE` | Radians | (1.5708, −0.2) |
| `on_ground` | `BOOLEAN` | Touched the ground in the last physics step | `TRUE` |
| `held` | `PLS_INTEGER` | Material placed on right-click | 2 (stone) |
| `last_tick` | `TIMESTAMP` | When the last tick ran, for measuring dt | — |

**Eye position** = (px, py + 1.62, pz).

### 5.6 Tables (the saved copy)

| Table | Columns | Key | Purpose |
| --- | --- | --- | --- |
| `PC_WORLD` | world\_id, seed, size\_x, size\_y, size\_z, gen\_version, gen\_params (JSON), created\_at | world\_id | One row per world |
| `PC_COLUMN` | world\_id, x, z, **blocks RAW(64)** | (world\_id, x, z) | One row per world column. **Byte y = material at height y.** 16,384 rows per world |
| `PC_PLAYER` | player\_id, world\_id, name, px, py, pz, yaw, pitch, held, saved\_at | player\_id | Where each player was |
| `PC_EDIT_LOG` | world\_id, seq (identity), x, y, z, old\_m, new\_m, player\_id, at | (world\_id, seq) | Every break/place. For debugging and undo |
| `PC_CONFIG` | name, value | name | Runtime settings (Section 14) |

**Why one row per column?** Loading 16,384 short rows with `BULK COLLECT` is fast. Loading a million one-block rows is not. Saving an edit rewrites **one 64-byte row**.

**Load path:** `BULK COLLECT` all columns of the world → unpack each RAW(64) into the block array (`RAWTOHEX` once per row, then read two hex characters per block) → build spans for every column → load the player. **Target ≤ 3 s.**

### 5.7 Package layout

Each package owns one job. Only `pc_engine` is called from outside; the rest are called directly only by tests.

| Package | Owns | State it keeps | Calls |
| --- | --- | --- | --- |
| `pc_const` | Sizes, material ids, tuning defaults | None (constants) | — |
| `pc_noise` | Seeded permutation, simplex 2D/3D, fBm | Permutation table | — |
| `pc_world` | Generate, load, save, get/set block, span rebuild | **Block array, span cache** | `pc_noise` |
| `pc_phys` | Mouse look, movement, collision, block raycast | **Player record** | `pc_world` |
| `pc_render` | Camera setup, column march, coverage list | Per-frame camera values | `pc_world`, `pc_frame` |
| `pc_frame` | Run buffer, header, BLOB packing | **Reused BLOB, hex lookup table** | — |
| `pc_engine` | Public API: `init_session`, `tick`, `save`, `shutdown` | Session flags | All of the above |

> **Package state is per session, and it dies on recompile.** If anyone recompiles a package while the game is running, the next call fails with **ORA-04068** ("existing state of packages has been discarded"). The middleware must catch it and call `init_session` again (Section 12). **Never** mark these packages `SERIALLY_REUSABLE`; that wipes state after every call.

## 6. Terrain generation

Terrain is built in **two phases that share one world format**. Phase 1 uses **2D simplex noise** for a height per column. Phase 2 adds a **3D density field** on top, which carves arches and overhangs. Generation runs **once per world**; the result is saved to `PC_COLUMN`, so its speed barely matters.

### 6.1 Seeded randomness

The same seed must always give the same world, on any Oracle version. So we **do not use `DBMS_RANDOM`**; its sequence for a given seed is not promised to stay the same across versions. We use the **Park–Miller "minimal standard" generator** instead:

```latex
s_{n+1} = 16807 \cdot s_n \bmod (2^{31} - 1)
```

- Start with s₀ = seed mod (2³¹ − 1). If that is 0, use 1.
- Do this maths in `NUMBER`. The product reaches about 3.6 × 10¹³, which overflows `PLS_INTEGER`. It only runs 255 times, so `NUMBER`'s slowness is irrelevant here.

**Permutation table.** Fill p\[0..255\] with 0..255. Shuffle with **Fisher–Yates**: for i from 255 down to 1, draw the next s, set j = s mod (i + 1), and swap p\[i\] and p\[j\]. Then build `perm[0..511]` with perm\[i\] = p\[i mod 256\]. The doubled table means `perm[a + perm[b]]` never needs a wrap.

### 6.2 2D simplex noise

This follows Stefan Gustavson's well-known reference version ("Simplex noise demystified", 2005). Input is a point (x, y); output is roughly **−1 to 1**.

**Constants:**

```latex
F_2 = \frac{\sqrt{3} - 1}{2} \approx 0.3660254 \qquad G_2 = \frac{3 - \sqrt{3}}{6} \approx 0.2113249
```

**Steps:**

1. **Skew** the input to find which grid cell it is in: s = (x + y) · F₂, then i = ⌊x + s⌋ and j = ⌊y + s⌋.
2. **Unskew** back to get the offset from that cell's first corner: t = (i + j) · G₂, then x₀ = x − (i − t) and y₀ = y − (j − t).
3. **Pick the triangle.** If x₀ > y₀ the middle corner is (i₁, j₁) = (1, 0); otherwise (0, 1).
4. **Offsets to the other two corners:** x₁ = x₀ − i₁ + G₂, y₁ = y₀ − j₁ + G₂, and x₂ = x₀ − 1 + 2G₂, y₂ = y₀ − 1 + 2G₂.
5. **Gradient for each corner.** With ii = i mod 256 and jj = j mod 256:
   - g₀ = perm\[ii + perm\[jj\]\] mod 8
   - g₁ = perm\[ii + i₁ + perm\[jj + j₁\]\] mod 8
   - g₂ = perm\[ii + 1 + perm\[jj + 1\]\] mod 8
6. **The 8 gradient directions:** (1,1), (−1,1), (1,−1), (−1,−1), (1,0), (−1,0), (0,1), (0,−1).
7. **Each corner's contribution**, for k = 0, 1, 2:

```latex
t_k = 0.5 - x_k^2 - y_k^2 \qquad n_k = \begin{cases} 0 & t_k < 0 \\ t_k^4 \,(g_x x_k + g_y y_k) & \text{otherwise} \end{cases}
```

8. **Result** = 70 × (n₀ + n₁ + n₂).

> **The scale factor 70** comes from the reference implementation. With our 8-gradient set, test **T-N2** (Section 15) measures the real output range over a million samples. Adjust the factor so the extremes land near ±1.

### 6.3 3D simplex noise (phase 2 only)

Same idea on a tetrahedral grid, with **4 corners** instead of 3.

- **Constants:** F₃ = 1/3, G₃ = 1/6.
- **Skew / unskew:** s = (x + y + z) · F₃, cell (i, j, k) = floors of (x + s, y + s, z + s). Then t = (i + j + k) · G₃, and (x₀, y₀, z₀) = (x, y, z) − ((i, j, k) − t).
- **Pick the tetrahedron** by sorting x₀, y₀, z₀. This table gives the 2nd and 3rd corners:

| Condition | Order | (i₁, j₁, k₁) | (i₂, j₂, k₂) |
| --- | --- | --- | --- |
| x₀ ≥ y₀ ≥ z₀ | x, y, z | (1, 0, 0) | (1, 1, 0) |
| x₀ ≥ z₀ > y₀ | x, z, y | (1, 0, 0) | (1, 0, 1) |
| z₀ > x₀ ≥ y₀ | z, x, y | (0, 0, 1) | (1, 0, 1) |
| z₀ > y₀ > x₀ | z, y, x | (0, 0, 1) | (0, 1, 1) |
| y₀ ≥ z₀ > x₀ | y, z, x | (0, 1, 0) | (0, 1, 1) |
| y₀ > x₀ ≥ z₀ | y, x, z | (0, 1, 0) | (1, 1, 0) |

- **Corner offsets:** corner 1 = (x₀, y₀, z₀) − (i₁, j₁, k₁) + G₃; corner 2 = (x₀, y₀, z₀) − (i₂, j₂, k₂) + 2G₃; corner 3 = (x₀, y₀, z₀) − 1 + 3G₃.
- **12 gradients** (cube edge midpoints): (±1, ±1, 0), (±1, 0, ±1), (0, ±1, ±1). Index = perm\[ii + perm\[jj + perm\[kk\]\]\] mod 12, with the corner offsets added to ii, jj, kk as in 2D.
- **Contribution:** t = 0.5 − x² − y² − z²; n = t⁴ · (g · offset) when t ≥ 0.
- **Result:** start with 32 × (n₀ + n₁ + n₂ + n₃) and calibrate with test **T-N3**.

> **Why 0.5 and not 0.6?** The original paper used 0.6 for 3D. That lets a corner's influence reach past its neighbours and causes faint seams. 0.5 is seam-free; the calibrated scale makes up the difference.

### 6.4 Height map (phase 1)

The height comes from **fBm**: several octaves of noise, each at double the frequency and half the strength. Dividing by the total weight keeps the sum between −1 and 1.

```latex
h(x, z) = B + A \cdot \frac{\sum_{o=0}^{O-1} g^{o} \cdot \text{noise2}\!\left(x F L^{o},\; z F L^{o}\right)}{\sum_{o=0}^{O-1} g^{o}}
```

| Symbol | Setting | Default | Effect |
| --- | --- | --- | --- |
| B | `TERRAIN_BASE` | 24 | Average ground height |
| A | `TERRAIN_AMP` | 16 | How far hills rise and valleys fall from B |
| F | `TERRAIN_FREQ` | 1/64 | Size of the biggest hills. 1/64 ≈ one hill every 64 blocks |
| O | `TERRAIN_OCTAVES` | 4 | Layers of detail |
| L | `TERRAIN_LACUNARITY` | 2.0 | Frequency multiplier per octave |
| g | `TERRAIN_GAIN` | 0.5 | Strength multiplier per octave |

With these defaults h stays between **8 and 40**. The column's solid height is **H = round(h)**, clamped to **2–60**. The top solid block sits at y = H − 1.

*Worked example.* Suppose the four octaves return 0.5, −0.2, 0.1 and 0.4.

- Weighted sum: 0.5 × 1 + (−0.2) × 0.5 + 0.1 × 0.25 + 0.4 × 0.125 = **0.475**
- Total weight: 1 + 0.5 + 0.25 + 0.125 = **1.875**
- Normalised: 0.475 ÷ 1.875 = **0.2533**
- h = 24 + 16 × 0.2533 = **28.05**, so H = **28**. The top block is at y = 27.

**Cost:** 16,384 columns × 4 octaves ≈ 65,000 noise calls. Trivial.

### 6.5 Materials (phase 1)

For a column with solid height H, using `SEA_LEVEL` = 20 and `SNOW_LINE` = 44:

| Height y | Material | Rule |
| --- | --- | --- |
| y = 0 | Bedrock | Always |
| 1 ≤ y ≤ H − 5 | Stone | Deep ground |
| H − 4 ≤ y ≤ H − 2 | Dirt | 3 layers under the top. **Sand** instead on beach columns |
| y = H − 1 | Grass | Top block. **Sand** if y ≤ SEA\_LEVEL + 1 (beach). **Snow** if y ≥ SNOW\_LINE |
| H ≤ y < SEA\_LEVEL | Water | Fills low ground up to sea level |
| everything else | Air |  |

*Example:* H = 28 gives bedrock at 0, stone 1–23, dirt 24–26, grass at 27. H = 19 gives a beach: sand 15–18, then water at y = 19.

### 6.6 Arches and overhangs (phase 2)

A heightmap can only say "solid below H, air above". For arches we need a **3D density field**. A block is solid when density is above zero:

```latex
D(x, y, z) = \text{noise3}\!\left(\frac{x}{32}, \frac{y}{24}, \frac{z}{32}\right) + \frac{h(x, z) - y}{S}
```

Here h is the **unrounded** height from 6.4 and S is `SQUASH` (default **8**).

**How to read it:**

- **Deep underground** (y < h − S): the second term is above +1. Noise can never go below −1, so D > 0. **Always solid.**
- **High in the air** (y > h + S): the second term is below −1. **Always air.**
- **Within S blocks of the surface:** noise decides. That is where **arches, overhangs, holes and floating rocks** come from.
- y is divided by 24 but x and z by 32, so features are **slightly stretched vertically**. That makes tall arches more likely than flat shelves.

**Only evaluate the band.** Outside y ∈ \[h − S, h + S\] the answer is known without any noise. That is about **16,384 × 17 ≈ 280,000** calls to noise3, run once.

**Materials after phase 2.** Walk each column **from the top down**, counting blocks since the last air block. The first solid block under air gets the top material (grass, sand or snow, as in 6.5). The next 3 get dirt. Everything deeper gets stone. y = 0 is always bedrock.

| Setting | Smaller value | Larger value |
| --- | --- | --- |
| `SQUASH` (S) | Flatter. Few overhangs | Wild. More arches, more floating rocks |
| `DENSITY_FREQ_XZ` (32) | Smaller, busier features | Wide, gentle features |
| `DENSITY_FREQ_Y` (24) | Tall, thin features | Flat, shelf-like features |

> **Known side effect: floating rocks.** The formula does not promise that every solid piece connects to the ground. v1 accepts this. A later clean-up pass could flood-fill from bedrock and delete anything unreached, at the cost of visiting a million blocks once.

## 7. Camera and projection maths

The camera casts **one 2D ray per screen column** across the ground grid. A clever choice of ray direction makes the ray's distance **equal the perpendicular depth**, so there is no fisheye and no correction step. Looking up and down is faked by **sliding the horizon row** (y-shearing).

In this section, **W = 640** and **H = 360** are the screen width and height in pixels. (Not to be confused with column height H in Section 6.)

### 7.1 Focal length

The focal length f says how many pixels one world unit covers at depth 1. We use **square pixels**, so the same f works horizontally and vertically.

```latex
f = \frac{W / 2}{\tan(\text{FOV}_h / 2)} \qquad \text{FOV}_v = 2 \arctan\!\left(\frac{H / 2}{f}\right)
```

*Example:* with FOV\_h = 90°, f = 320 ÷ tan 45° = **320**, and FOV\_v = 2 × arctan(180 ÷ 320) = **58.7°**.

### 7.2 One ray per screen column

Work in the ground plane only: (x, z). Let **F** be the forward vector and **R** the right vector (Section 5.1), and P = tan(FOV\_h ÷ 2). For screen column c:

```latex
\text{cam}_c = \frac{2(c + 0.5)}{W} - 1 \qquad \mathbf{d}_c = \mathbf{F} + P \cdot \text{cam}_c \cdot \mathbf{R}
```

- cam\_c runs from about −1 (left edge) to +1 (right edge). The **+0.5** samples each column at its centre.
- **d\_c is deliberately not normalised.** Because F and R are perpendicular and F has length 1, **F · d\_c = 1 for every column**.
- So a point on the ray, E + t · d\_c, is exactly **t units in front of the camera**. The ray parameter t *is* the perpendicular depth. Walls straight ahead and at the screen edges come out the right size, with no fisheye.

*Example:* facing east (θ = 0), F = (1, 0), R = (0, 1), P = 1. Column 0 has cam₀ = 1/640 − 1 = −0.9984, so d₀ = (1, −0.9984). That points north-east. Facing east, your left is north. ✔

> **Precompute cam\_c once.** It depends only on the screen width, never on the camera. Store the 640 values in a collection at `init_session`.

### 7.3 From height and depth to a screen row

Screen rows count **downward** from 0 at the top. A point at world height y and depth t lands on row:

```latex
\text{row}(y, t) = h - f \cdot \frac{y - e_y}{t} \qquad h = \frac{H}{2} + f \tan\varphi
```

- **e\_y** is the eye height: feet + 1.62.
- **h** is the **horizon row**, where things at eye height appear. φ is pitch, positive when looking up.
- Looking **up** moves the horizon **down** the screen, so more sky shows. That is the y-shearing.

*Example:* eye at e\_y = 25.62, looking level (h = 180). The top of a block at y = 24, 10 units away, lands on row 180 − 320 × (24 − 25.62) ÷ 10 = **231.8**. It is below the horizon because it is below your eyes.

**Compute 1/t once per depth, then reuse it.** Each grid cell needs rows at two depths (Section 8). Two divisions per cell, then only multiplies.

### 7.4 Pitch limit

Y-shearing slides the image instead of tilting the camera. Vertical lines stay vertical, which is wrong but cheap. It looks fine up to about **±35°** and stretched beyond that. `PITCH_LIMIT` defaults to **35°**.

| Pitch φ | Horizon shift f · tan φ (pixels) | Horizon row looking up | Horizon row looking down |
| --- | --- | --- | --- |
| 0° | 0 | 180 | 180 |
| 20° | 116.5 | 296.5 | 63.5 |
| 30° | 184.8 | 364.8 (off screen) | −4.8 (off screen) |
| 35° | 224.1 | 404.1 (off screen) | −44.1 (off screen) |

A horizon row off the screen is fine. Every formula still works.

### 7.5 Where the crosshair points

The screen centre (row H/2) must point exactly where block targeting aims (Section 11). Take a point straight ahead at depth t and height e\_y + t · tan φ. Section 7.3 puts it at row h − f · tan φ = **H/2**. So the crosshair looks along:

```latex
\mathbf{L} = (\cos\theta \cos\varphi,\; \sin\varphi,\; \sin\theta \cos\varphi)
```

That is the ordinary unit look vector. **Use L for targeting**, and what you click is what is under the crosshair, even though the rest of the image is sheared.

> **Known limitation: you cannot target your own feet.** At the −35° limit, the crosshair ray hits the floor 1.62 ÷ tan 35° ≈ **2.3 blocks ahead**. The block you stand on, and the ones right next to your feet, cannot be clicked. Raising `PITCH_LIMIT` to 45° brings this to 1.6 blocks, with more stretching. Listed in Section 17.

### 7.6 Near plane

Any depth below **t\_near = 0.05** is clamped to 0.05. This avoids dividing by zero when the camera is right next to a wall, and keeps row numbers finite.

### 7.7 Per-frame camera setup

Once at the start of each render:

| Value | Formula | Type |
| --- | --- | --- |
| Eye (e\_x, e\_y, e\_z) | (px, py + 1.62, pz) | `BINARY_DOUBLE` × 3 |
| F | (cos θ, sin θ) | `BINARY_DOUBLE` × 2 |
| R | (−sin θ, cos θ) | `BINARY_DOUBLE` × 2 |
| P · R | Precomputed so each column needs one multiply-add per axis | `BINARY_DOUBLE` × 2 |
| h | H/2 + f · tan φ | `BINARY_DOUBLE` |
| Eye cell | (⌊e\_x⌋, ⌊e\_z⌋) | `SIMPLE_INTEGER` × 2 |

## 8. Column renderer

For each of the 640 screen columns, walk the ground grid **front to back**. In each grid cell, project that column's spans to screen rows and paint **only rows nobody has painted yet**. Stop when the column is full. Because the walk is front to back, **the first thing to claim a row is always the nearest**, so there is no depth buffer and no sorting.

### 8.1 One column, step by step

1. **Set up the 2D ray** for column c (Section 7.2) and the DDA (8.2).
2. **Reset the coverage list** to one open interval: rows 0–359 (8.5).
3. **Start in the eye's own cell** with entry depth t\_in = 0.
4. **Loop:**
   1. Find the exit depth t\_out of the current cell (8.2).
   2. **Draw the cell's spans** for depths t\_in to t\_out (8.3).
   3. **Stop** if the coverage list is empty, if t\_out > `FAR`, if the next cell is outside the world, or if the early-out in 8.6 fires.
   4. Step to the next cell. Its entry depth is this cell's exit depth.
5. **Fill what is left with sky** (8.7).

### 8.2 The 2D DDA walk

This is the Amanatides–Woo grid walk (1987). It visits **every cell the ray crosses, in order**, using only adds and compares in the loop.

**Setup** (once per column), with eye position (e\_x, e\_z) and ray d = (d\_x, d\_z):

| Value | Formula | Meaning |
| --- | --- | --- |
| (m\_x, m\_z) | (⌊e\_x⌋, ⌊e\_z⌋) | Current cell |
| δ\_x | \|1 / d\_x\| (use 10³⁰ if d\_x = 0) | Depth gained per whole cell crossed in x |
| δ\_z | \|1 / d\_z\| (same rule) | Depth gained per whole cell crossed in z |
| step\_x | +1 if d\_x > 0, else −1 | Direction to move in x |
| side\_x | (m\_x + 1 − e\_x) · δ\_x if d\_x > 0, else (e\_x − m\_x) · δ\_x | **Depth at which the ray next crosses an x grid line** |
| side\_z | Same idea for z | Depth of the next z grid line |

**Each step:**

- **t\_out = min(side\_x, side\_z).** That is where the ray leaves the current cell.
- If side\_x < side\_z: move to m\_x + step\_x and add δ\_x to side\_x. The next cell is **entered through an x-facing wall** (its east or west face).
- Otherwise: move to m\_z + step\_z, add δ\_z to side\_z. **Entered through a z-facing wall.**
- Remember which axis you entered by. It picks the wall's shade (8.7).

Because d is not normalised (Section 7.2), **side\_x and side\_z are already perpendicular depths**. No conversion.

*Example:* eye at (5.3, 7.8), ray (1, 0.5). δ\_x = 1, δ\_z = 2. side\_x = 0.7 × 1 = **0.7**. side\_z = 0.2 × 2 = **0.4**. The ray leaves the eye cell at t = 0.4 through the south edge, into cell (5, 8). Next, side\_z becomes 2.4 and side\_x is still 0.7, so it leaves (5, 8) at t = 0.7 into (6, 8).

### 8.3 Drawing one cell

Given the cell's entry depth t\_in (clamped to at least 0.05) and exit depth t\_out, compute two factors **once**:

```latex
a = \frac{f}{t_{in}} \qquad b = \frac{f}{t_{out}} \qquad r_{in}(y) = h - (y - e_y)\,a \qquad r_{out}(y) = h - (y - e_y)\,b
```

r\_in(y) is where height y appears at the cell's **near edge**; r\_out(y) at its **far edge**. Each span \[y0, y1) can show up to three faces:

| Face | Visible when | Continuous rows | Shade |
| --- | --- | --- | --- |
| **Wall** (near side of the cell) | Not the eye's own cell | r\_in(y1) to r\_in(y0) | x-wall or z-wall, by entry axis |
| **Top** | Eye is above it: y1 < e\_y | r\_out(y1) to r\_in(y1) | Top |
| **Underside** | Eye is below it: y0 > e\_y | r\_in(y0) to r\_out(y0) | Underside |

The eye's own cell has no near wall, but its top and underside faces still matter: they are the floor under you and any ceiling above you.

**Paint order inside a cell (nearest first):**

1. **All walls.** They sit at depth t\_in, nearer than anything else in the cell. Spans never overlap, so walls never fight each other.
2. **Tops of spans below the eye, highest first.** A higher top is between you and a lower one.
3. **Undersides of spans above the eye, lowest first.** Same logic, mirrored.

> **Hidden faces need no special code.** Take dirt \[20, 23) under grass \[23, 24). The dirt's top at y = 23 lies inside the grass. The grass wall and grass top claim those rows first, so the dirt top finds nothing open and paints nothing. Walls hidden behind a nearer cell work the same way. **The coverage list is the only visibility test.**

*Worked example.* Eye at e\_y = 25.62, level (h = 180), f = 320. A cell from t\_in = 4 to t\_out = 5 holds grass \[23, 24).

- a = 320 ÷ 4 = 80, b = 320 ÷ 5 = 64.
- **Wall:** r\_in(24) = 180 − (24 − 25.62) × 80 = **309.6**; r\_in(23) = 180 + 2.62 × 80 = **389.6**. Rows 310–359 (clipped at the screen bottom).
- **Top:** r\_out(24) = 180 + 1.62 × 64 = **283.7**, down to r\_in(24) = **309.6**. Rows 284–309.
- The wall's top edge and the top face's bottom edge are the **same number, 309.6**, so they meet with no gap and no overlap.

### 8.4 Rounding to whole rows

A continuous range \[y\_a, y\_b) paints whole rows **R(y\_a) to R(y\_b) − 1**, where:

```latex
R(y) = \left\lfloor \operatorname{clamp}(y,\, 0,\, H) + 0.5 \right\rfloor
```

- **Clamp first**, then round. Near the camera, rows can be in the thousands; clamping keeps every value a small integer.
- **Compute each edge once and reuse it.** Two faces that share an edge then round to the same row, so there are never gaps or double-painted rows between them.
- An empty result (R(y\_a) ≥ R(y\_b)) paints nothing. That happens for faces seen edge-on.

### 8.5 The coverage list

Per screen column, keep the **rows not yet painted** as a short sorted list of closed intervals \[lo, hi\]. Also keep **min\_open** and **max\_open** (the first and last open rows) for fast rejects.

- **Start:** one interval, \[0, 359\].
- **Capacity:** 32 intervals. Each fill can split one interval into two, and real columns stay well under 10.
- **Storage:** two small collections, `lo(1..32)` and `hi(1..32)`, plus a count. Reused for every column.

**fill(a, b, colour)**, for whole rows a to b inclusive:

1. If b < min\_open or a > max\_open, return. Nothing to do.
2. For each open interval \[lo, hi\] that overlaps \[a, b\]:
   1. **Emit a run** from max(lo, a) to min(hi, b) in this colour (Section 9).
   2. Replace the interval with what is left of it: \[lo, a − 1\] if lo < a, and \[b + 1, hi\] if b < hi. That is zero, one or two pieces.
3. Recompute min\_open and max\_open. The column is **full when the list is empty**.

*Example: looking at an arch.*

| Step | Paints | Open rows after |
| --- | --- | --- |
| Start | — | \[0, 359\] |
| Near ground top, rows 300–359 | 300–359 | \[0, 299\] |
| Hill wall, rows 240–310 | **240–299** (rows 300–310 were taken) | \[0, 239\] |
| Arch underside, rows 100–130 | 100–130 | \[0, 99\], \[131, 239\] |
| Far hill wall, rows 180–250 | **180–239** | \[0, 99\], \[131, 179\] |
| Sky fill | 0–99, 131–179 | empty |

The sky shows **through the arch** (rows 131–179) and above it (0–99). That is the overhang case a plain heightmap cannot draw.

### 8.6 Early-outs

Without these, every column walks to `FAR`. They are what make the budget in Section 4 realistic.

**(a) Column full.** Coverage list empty: stop the column.

**(b) Span break inside a cell.** Split the cell's spans at the eye: let k\_b be the **highest span whose bottom is below the eye** (y0 < e\_y). Spans 0..k\_b are at or below eye level; the rest are above. Then:

| Pass | Walk spans | Paint | Stop the pass when |
| --- | --- | --- | --- |
| Walls, lower | k\_b down to 0 | Wall | R(r\_in(y1)) > max\_open |
| Walls, upper | k\_b + 1 up to n − 1 | Wall | R(r\_in(y0)) < min\_open |
| Tops | k\_b down to 0, only if y1 < e\_y | Top | R(r\_out(y1)) > max\_open |
| Undersides | k\_b + 1 up to n − 1 | Underside | R(r\_out(y0)) < min\_open |

*Why it is safe:* spans are sorted and do not overlap, so every span below span k is also **lower on screen**. Once one span is entirely below every open row, all the spans under it are too. In flat terrain this means **only the top span or two are ever checked**.

**(c) Nothing tall enough is left.** Keep **g\_max\_y**, the highest span top in the whole world (update it when a block is placed above it). For the rest of the walk, every face lies between y = 0 and y = g\_max\_y, and depths lie between t\_in and `FAR`. So the only rows still reachable are:

```latex
\text{top} = \min\big(r(g_{max}, t_{in}),\; r(g_{max}, \text{FAR})\big) \qquad \text{bottom} = \max\big(r(0, t_{in}),\; r(0, \text{FAR})\big)
```

If no open interval touches \[top, bottom\], **stop the column**: everything still open is sky. This is the big one. Looking across open land, the rows above the hills stay open, and without this check the walk would run to `FAR` in every column just to confirm they are sky. Check it **every 4 cells**, not every cell; it costs four multiplies and a divide.

**(d) Distance.** Stop when t\_out > `FAR`.

**(e) World edge.** Stop when the next cell is outside 0–127.

### 8.7 Shading, fog and sky

Every painted face gets a **palette index = material × 16 + level** (Section 9). The level combines **which way the face points** with **how far away it is**:

```latex
\text{level} = 4 \cdot \text{band} + \text{face}
```

**Face kind** (0–3):

| Face | Value | Looks |
| --- | --- | --- |
| Top | 0 | Brightest |
| x-wall (east/west face) | 1 | Slightly darker |
| z-wall (north/south face) | 2 | Darker |
| Underside | 3 | Darkest |

**Fog band** (0–3), from the cell's entry depth t\_in, with `FOG_START` = 24 and `FOG_STEP` = (`FAR` − `FOG_START`) ÷ 3 = 8:

```latex
\text{band} = \operatorname{clamp}\!\left(\left\lfloor \frac{t_{in} - \text{FOG\_START}}{\text{FOG\_STEP}} \right\rfloor + 1,\; 0,\; 3\right)
```

| Depth t\_in | Band |
| --- | --- |
| below 24 | 0 (clear) |
| 24 to 32 | 1 |
| 32 to 40 | 2 |
| 40 to 48 | 3 (almost sky-coloured) |

*Example:* a grass (material 4) x-wall at depth 30 → band 1, face 1 → level 4 × 1 + 1 = **5** → palette index 4 × 16 + 5 = **69**.

> **Why stepped fog?** Band 3 is tinted almost to the sky colour. So when the walk stops at `FAR`, terrain fades into the sky with no visible edge. Stepped bands also keep runs long (Section 9), which keeps the output small.

**Sky.** Material 0 (air) is reused for sky, so sky indices are 0–15. The sky fill splits each open interval at **three rows relative to the horizon** (h − 120, h − 60, h − 20) and uses indices 0–3, lighter toward the horizon. That is at most 4 runs per open interval.

### 8.8 Cost summary

| Work | Per column | Per frame (× 640) |
| --- | --- | --- |
| DDA steps | ≈ 71 average, 98 worst (fewer with early-out c) | ≈ 45,500 |
| Divisions | 1 per cell (b; a is the last cell's b) | ≈ 45,500 |
| Spans checked | 1–2 per cell after the span break | ≈ 45,000–90,000 |
| Runs emitted | ≈ 10–30 | ≈ 15,000 |

> **Reuse the divide.** A cell's entry depth is the previous cell's exit depth, so **a for this cell is b from the last one**. One division per cell, not two.

## 9. Frame format and palette

A frame is a **52-byte header followed by a list of runs per screen column**. A typical frame is about **76 KB**. The browser never sees colours from the database, only **palette indices**; the palette itself lives in JavaScript.

### 9.1 Byte layout

**All multi-byte numbers are big-endian, unsigned.** Big-endian because PL/SQL writes hex text high byte first; the browser reads with `DataView.getUint16(offset, false)`.

**Header (52 bytes):**

| Offset | Bytes | Field | Meaning | Example |
| --- | --- | --- | --- | --- |
| 0 | 2 | `magic` | Always 0x50 0x43 ("PC") | 50 43 |
| 2 | 1 | `version` | Format version | 1 |
| 3 | 1 | `flags` | bit 0: target fields valid · bit 1: world edited this tick · bit 2: debug heat-map frame | 0x01 |
| 4 | 4 | `seq` | Sequence number of the input this frame answers | 1834 |
| 8 | 2 | `width` | Screen width in pixels | 640 |
| 10 | 2 | `height` | Screen height in pixels | 360 |
| 12 | 4 | `render_us` | Microseconds spent rendering | 18,250 |
| 16 | 2 | `phys_us` | Microseconds in mouse look and physics | 310 |
| 18 | 2 | `edit_us` | Microseconds in break/place (0 if no click) | 0 |
| 20 | 2 | `pack_us` | Microseconds packing runs | 4,100 |
| 22 | 2 | — | Reserved, write 0 | 0 |
| 24 | 4 | `px_milli` | Feet x × 1000 | 64,500 = 64.5 |
| 28 | 4 | `py_milli` | Feet y × 1000 | 24,000 = 24.0 |
| 32 | 4 | `pz_milli` | Feet z × 1000 | 64,500 = 64.5 |
| 36 | 2 | `yaw_e4` | Yaw in radians × 10,000, range 0–62,831 | 15,708 = 90° |
| 38 | 2 | `pitch_e4` | Pitch × 10,000 **+ 32,768** (offset so it stays unsigned) | 30,768 = −0.2 rad |
| 40 | 1 | `held` | Material placed on right-click | 2 |
| 41 | 1 | `target_face` | Face under the crosshair: 0 −x, 1 +x, 2 −y, 3 +y, 4 −z, 5 +z, 255 none | 3 |
| 42 | 2 | `target_x` | Block under the crosshair | 66 |
| 44 | 2 | `target_y` |  | 23 |
| 46 | 2 | `target_z` |  | 65 |
| 48 | 4 | `run_total` | Total runs in the frame, for checking | 14,820 |

**Body:** for each screen column c = 0 to width − 1, in order:

| Bytes | Field | Meaning |
| --- | --- | --- |
| 2 | `run_count` | Runs in this column |
| 5 × run\_count | runs | Each: `start_row` (2 bytes), `length` (2 bytes), `palette_index` (1 byte) |

- Runs are in **paint order** (nearest first), **not** row order. The browser does not care.
- **Every row is covered exactly once.** The lengths in a column always add up to the height. That is the main correctness check (test T-R1).
- **Typical size:** 52 + 640 × 2 + 15,000 × 5 ≈ **76 KB**.
- **Worst case:** 360 one-row runs in every column ≈ **1.15 MB**. Buffers must allow for it (Section 12).

*Example column:* bytes `00 03 | 00 00 00 B4 00 | 00 B4 00 28 45 | 00 DC 00 8C 42` mean 3 runs: rows 0–179 sky (index 0), rows 180–219 index 69 (grass x-wall, fog band 1), rows 220–359 index 66.

### 9.2 Packing in PL/SQL

PL/SQL has no cheap way to write single bytes, so we build **hex text** and convert it in big chunks.

1. **Hex table.** At `init_session`, fill `g_hex(0..255)` with '00' to 'FF'.
2. **Writing numbers.** One byte v → `g_hex(v)`. Two bytes → `g_hex(TRUNC(v / 256)) || g_hex(MOD(v, 256))`. (No bit shifts in PL/SQL, so we divide.)
3. **Per-column staging.** The run count comes *before* the runs, but we only know it when the column is done. So runs go into a short column string first. At column end, append the 2-byte count and then the column string to the main buffer.
4. **Main buffer.** A `VARCHAR2(32767)`. When it passes **32,000 characters**, convert with `HEXTORAW` (giving up to 16,383 bytes, well inside RAW's 32,767 limit) and append to the BLOB with `DBMS_LOB.WRITEAPPEND`. Then empty the buffer.
5. **One BLOB, reused.** Create it once in `init_session` with `DBMS_LOB.CREATETEMPORARY` (cache on, session duration). Each frame: `DBMS_LOB.TRIM` to 0, write **52 zero bytes** as a placeholder header, append all columns, then overwrite the header with `DBMS_LOB.WRITE` at offset 1. The header goes last because it contains `pack_us`.

> **Why reuse the BLOB?** Creating a temporary LOB every frame means 24 allocations per second in the temporary tablespace, and leaks if one is ever not freed. One session-long BLOB avoids both. It is safe because the client reads each frame fully before sending the next input (Section 12).

> **Fallback if B5 fails.** Return the frame as a collection of `RAW(32767)` chunks instead of a BLOB. More binding work in Node, but no LOB calls at all.

### 9.3 Decoding in the browser

1. Set the WebSocket's `binaryType` to `'arraybuffer'`. Wrap each message in a `DataView`.
2. **Check** magic, version, and that `seq` is the one we are waiting for.
3. Create **once**: an `ImageData` of 640 × 360, a `Uint32Array` view of its pixels (`pix`), and a `Uint32Array(256)` palette (`pal32`).
4. **For each column c:** read `run_count`. For each run, read start, length and index, then set `pix[row × 640 + c] = pal32[index]` for each row in the run.
5. `putImageData` into a hidden 640 × 360 canvas, then `drawImage` it onto the visible canvas, scaled to the window with `imageSmoothingEnabled = false` (CSS `image-rendering: pixelated`). Crisp pixels at any window size.

**Cost:** 230,400 array writes. Well under 2 ms in any current browser.

> **Byte order of `pal32`.** Pixel bytes in `ImageData` are R, G, B, A in memory. On little-endian machines (all real phones and PCs), a `Uint32` holding one pixel is therefore **0xAABBGGRR**. Build `pal32` that way.

### 9.4 Palette maths

**256 entries.** Index = material × 16 + level, and level = 4 × band + face (Section 8.7).

```latex
\text{colour}(m, \text{band}, \text{face}) = (1 - \alpha_{band}) \cdot \big(\text{base}(m) \cdot s_{face}\big) + \alpha_{band} \cdot \text{fog}
```

Apply this to each of R, G and B, then round and clamp to 0–255.

| Face | s\_face (shade) |
| --- | --- |
| Top | 1.00 |
| x-wall | 0.80 |
| z-wall | 0.65 |
| Underside | 0.50 |

| Fog band | α\_band (fog amount) |
| --- | --- |
| 0 | 0.00 |
| 1 | 0.30 |
| 2 | 0.60 |
| 3 | 0.88 |

**fog** = the sky colour at the horizon, so band 3 melts into the sky.

**Base colours (day):**

| Id | Material | RGB |
| --- | --- | --- |
| 1 | Bedrock | (60, 60, 60) |
| 2 | Stone | (125, 125, 125) |
| 3 | Dirt | (134, 96, 67) |
| 4 | Grass | (95, 159, 53) |
| 5 | Sand | (219, 207, 163) |
| 6 | Water | (48, 96, 200) |
| 7 | Log | (102, 81, 51) |
| 8 | Leaves | (60, 120, 40) |
| 9 | Planks | (162, 130, 78) |
| 10 | Cobblestone | (110, 110, 110) |
| 11 | Brick | (150, 74, 58) |
| 12 | Snow | (240, 245, 250) |

**Sky (material 0):** indices 0–3 run from the top of the sky to the horizon: (110, 160, 230), (130, 175, 235), (155, 195, 240), (185, 215, 245). Indices 4–15 are unused.

*Worked example:* index 69 is grass, x-wall, band 1. Shaded: (95, 159, 53) × 0.80 = (76, 127.2, 42.4). Fogged 30% toward (185, 215, 245): **(109, 154, 103)**.

### 9.5 Effects that cost the database nothing

The palette is recomputed in JavaScript, 256 entries, whenever we like:

- **Day/night:** blend sky colours and a global light multiplier between day and night presets. Fog follows the horizon colour.
- **Damage flash:** blend every entry 30% toward red for 150 ms.
- **Debug heat map:** with flag bit 2 set, the server paints each column one colour whose index is the number of cells walked (capped at 255). The browser shows it with a blue-to-red ramp. This is the fastest way to see where the renderer spends its time.

## 10. Input, physics and collision

Each tick applies the latest input, then runs physics in **small fixed sub-steps** (at most 1/60 s) so fast falls can never skip through a block. Collision resolves **one axis at a time** against the dense block array.

### 10.1 Input message

The browser sends one small JSON message per frame:

```json
{ "seq": 1834, "keys": 21, "mdx": -14, "mdy": 3, "lclick": 0, "rclick": 1, "held": 2 }
```

| Field | Type and range | Meaning | Example |
| --- | --- | --- | --- |
| `seq` | Integer, counts up from 1 | Matches the input to its frame | 1834 |
| `keys` | Bitmask, 0–127 | Keys **held down right now** (table below) | 21 = W + A + Space |
| `mdx`, `mdy` | Integers, pixels | **Mouse movement since the last message** (sum of Pointer Lock `movementX/Y`) | −14, 3 |
| `lclick`, `rclick` | 0 or 1 | A left / right click happened since the last message | 0, 1 |
| `held` | 2–12 (placeable ids) | Material to place, chosen with number keys | 2 (stone) |

**Key bits:**

| Bit | Value | Key | Action |
| --- | --- | --- | --- |
| 0 | 1 | W | Forward |
| 1 | 2 | S | Back |
| 2 | 4 | A | Left |
| 3 | 8 | D | Right |
| 4 | 16 | Space | Jump |
| 5 | 32 | Shift | Sneak (slow walk) |
| 6 | 64 | Ctrl | Sprint |

*Example:* keys = 21 = 1 + 4 + 16 → forward, left and jump at once.

### 10.2 Mouse look

```latex
\theta \leftarrow (\theta + \text{mdx} \cdot k) \bmod 2\pi \qquad \varphi \leftarrow \operatorname{clamp}(\varphi - \text{mdy} \cdot k,\; -\varphi_{max},\; +\varphi_{max})
```

- k is `MOUSE_SENS`, default **0.0025 radians per pixel**: 400 pixels of mouse travel turns you about 57°.
- **Minus mdy** because moving the mouse up gives a negative `movementY`, and moving up should look up.
- φ\_max is `PITCH_LIMIT` (35°).

### 10.3 Time step

1. **Measure dt** as the time since the last tick, from two `SYSTIMESTAMP` values. Clamp it to **0–0.1 s**, so a stall cannot launch the player across the map.
2. **Split into N sub-steps:** N = ⌈dt ÷ (1/60)⌉, each of length s = dt ÷ N.
3. Run 10.4 and 10.5 once per sub-step.

*Why 1/60?* At the terminal fall speed of 40 blocks per second, one sub-step moves at most 40 ÷ 60 = **0.67 blocks**. Less than one block, so the collision check can never miss a block entirely. At 24 fps, dt ≈ 0.042 s gives **3 sub-steps**.

### 10.4 Movement (each sub-step)

**Horizontal.** Build a wish direction from the keys, using F = (cos θ, sin θ) and R = (−sin θ, cos θ) on the ground plane:

```latex
\mathbf{w} = \mathbf{F}\,(W - S) + \mathbf{R}\,(D - A)
```

Each key letter is 1 if held, 0 if not. If w is not zero, scale it to length 1 so diagonals are not faster.

- **On the ground:** horizontal velocity = w × speed, instantly. Snappy and simple.
- **In the air:** move toward that velocity gradually: v += (target − v) × min(1, 5 × s). You keep some control mid-jump but cannot turn on a dime.

| Mode | Speed (blocks per second) | Setting |
| --- | --- | --- |
| Walk | 4.3 | `WALK_SPEED` |
| Sprint (Ctrl) | 5.6 | `SPRINT_SPEED` |
| Sneak (Shift) | 1.3 | `SNEAK_SPEED` |

**Vertical.**

- **Jump:** if Space is held and you are on the ground, set v\_y to the speed that reaches `JUMP_HEIGHT`:

```latex
v_{jump} = \sqrt{2\, g\, h_{jump}} = \sqrt{2 \times 28 \times 1.25} \approx 8.37 \text{ blocks/s}
```

- That gives about **0.6 s in the air**, enough to clear a one-block step.
- **Gravity:** v\_y ← max(v\_y − g × s, −40), with g = `GRAVITY` = 28 blocks/s² and −40 = `TERMINAL_VEL`.

### 10.5 Collision

The player is an **AABB** (axis-aligned bounding box) 0.6 wide, 1.8 tall, 0.6 deep, with the feet at its bottom centre:

```latex
[p_x - 0.3,\; p_x + 0.3] \times [p_y,\; p_y + 1.8] \times [p_z - 0.3,\; p_z + 0.3]
```

**Move one axis at a time, in the order y, then x, then z.** For each axis:

1. **Proposed move:** Δ = v × s on this axis.
2. **Find candidate blocks:** every block cell that overlaps the box **stretched by Δ** along this axis. That is at most 3 × 4 × 3 = 36 cells.
3. **For each solid one** that also overlaps the box on the other two axes, shrink Δ so the box stops at its face:
   - Moving + on this axis: Δ ≤ (block's near face) − (box's leading edge) − ε
   - Moving −: Δ ≥ (block's far face) − (box's leading edge) + ε
4. **Apply Δ.** If it was shrunk, set velocity on this axis to 0.
5. **On the y axis only:** if moving down and Δ was shrunk, set `on_ground = TRUE`. If not shrunk, set it `FALSE`.

ε = **0.001** keeps the box from resting exactly on a face, which avoids floating-point "sticking". "Overlaps on the other two axes" uses **strict** inequalities with ε, so sliding along a wall works.

*Example:* feet at y = 24.02, falling with Δ = −0.1, ground block's top at y = 24. The limit is 24 + 0.001 − 24.02 = **−0.019**. Δ shrinks to −0.019, the feet land at **24.001**, v\_y becomes 0, and `on_ground` is true.

*Why y first?* Landing is resolved before sideways sliding, so walking off a ledge onto a lower block feels right, and you do not catch on the edge of the block you are standing on.

**World edges** count as solid (Section 5.3), so the player cannot leave the map.

### 10.6 Getting unstuck

If the box ever ends up inside a solid block (a bug, or an edit from another tool), move the player **up one block at a time, at most 3 times**, until it is clear. Log it. Placement rules in Section 11 should make this rare.

## 11. Block interaction

Breaking and placing both start with **one 3D ray from the eye along the crosshair** (Section 7.5), walked through the dense block array up to **5 blocks**. The first solid block it meets is the target; the empty cell just before it is where a new block goes. An edit changes **one world column**, so only that column's spans are rebuilt.

### 11.1 The 3D raycast

The same Amanatides–Woo walk as Section 8.2, with a third axis and a **unit-length** ray L, so depth here is real distance in blocks.

**Setup**, with eye e:

| Value | Formula |
| --- | --- |
| Current cell (i\_x, i\_y, i\_z) | (⌊e\_x⌋, ⌊e\_y⌋, ⌊e\_z⌋) |
| step\_a | +1 if L\_a > 0, else −1 (for a = x, y, z) |
| tDelta\_a | \|1 / L\_a\| (10³⁰ if L\_a = 0) |
| tMax\_a | (i\_a + 1 − e\_a) · tDelta\_a if L\_a > 0, else (e\_a − i\_a) · tDelta\_a |

**Loop:**

1. Pick the axis with the **smallest tMax**. If that tMax is beyond `REACH`, stop: **no target**.
2. Remember the current cell as **prev**. Step: i\_a += step\_a, tMax\_a += tDelta\_a.
3. If the new cell is outside the world, stop: no target.
4. If the new cell is **not air: hit.** Return the cell, prev, and the face it was entered through.

**Which face was hit:**

| Stepped | Face entered | Face number |
| --- | --- | --- |
| +x | West face (−x) | 0 |
| −x | East face (+x) | 1 |
| +y | Underside (−y) | 2 |
| −y | Top (+y) | 3 |
| +z | North face (−z) | 4 |
| −z | South face (+z) | 5 |

The face number goes in the frame header (`target_face`) so the browser can draw an outline on it.

*Worked example.* Eye at (64.5, 25.62, 64.5), facing east, looking 30° down: L = (0.866, −0.5, 0). Ground is solid up to y = 23.

| Step | Axis (tMax) | Enters cell | Solid? |
| --- | --- | --- | --- |
| 1 | x (0.577) | (65, 25, 64) | No |
| 2 | y (1.24) | (65, 24, 64) | No |
| 3 | x (1.732) | (66, 24, 64) | No |
| 4 | x (2.887) | (67, 24, 64) | No |
| 5 | y (3.24) | (67, 23, 64) | **Yes** |

Hit block **(67, 23, 64)** through its **top** (face 3). prev = (67, 24, 64), which is where a placed block would go. Check: the ray drops 1.62 to reach y = 24 after 1.62 ÷ 0.5 = 3.24, at x = 64.5 + 0.866 × 3.24 = 67.3. ✔

### 11.2 Break (left click)

1. Raycast. No target → do nothing.
2. **Bedrock cannot be broken.** If the target is material 1, do nothing.
3. Set the block to **air** (0).
4. **Rebuild that column's spans** (Section 5.4). 64 reads.
5. **Persist** (11.5) and set flag bit 1 in the frame header.

### 11.3 Place (right click)

1. Raycast. No target → do nothing.
2. The new block goes in **prev**, the last empty cell before the hit.
3. **Reject the place if any of these are true:**
   - prev is outside the world, or its y is 0 or ≥ 64.
   - **prev overlaps the player's box.** Use the box from 10.5 against the cell \[x, x+1\] × \[y, y+1\] × \[z, z+1\] with strict inequalities. Otherwise you could bury yourself.
   - `held` is not a placeable material (Section 5.2).
4. Set the block to `held`, rebuild that column's spans, and raise **g\_max\_y** if y + 1 is above it (it feeds early-out (c) in Section 8.6).
5. Persist (11.5).

### 11.4 Order inside one tick

The order matters, because the frame must show the result of this tick's input:

1. Mouse look (10.2)
2. Physics sub-steps (10.3–10.5)
3. Raycast from the **new** eye position
4. Break, if `lclick`. Then **raycast again** and place, if `rclick`. (Both in one tick is rare but legal.)
5. Render (Section 8)
6. Pack and return (Section 9)

### 11.5 Saving edits

- **Update one row:** `PC_COLUMN.blocks` for that (world\_id, x, z). Build the new RAW(64) from the column's 64 blocks with the hex table, then `HEXTORAW`.
- **Log it:** insert into `PC_EDIT_LOG` (position, old and new material, player, time).
- **Commit every 2 seconds, not every edit** (`COMMIT_INTERVAL_S`). A commit waits for a disk write, which can blow a frame's budget. A crash loses at most 2 seconds of edits.
- **Player position** is saved every 10 seconds (`SAVE_INTERVAL_S`) and on `engine.shutdown`.

## 12. Middleware and browser client

A small **Node.js** server holds **one dedicated Oracle connection per player** and relays over a **WebSocket**: inputs up, frames down. The browser runs **lockstep**: it sends the next input only after the previous frame arrives, so there is never more than one frame in flight.

### 12.1 Why not ORDS

ORDS hands each HTTP request to **whichever pooled database session is free**. Our world and player live in **package state, which belongs to one session**. With ORDS, consecutive frames could land in different sessions: an empty world, a different player, or another player's world. A dedicated connection guarantees every tick hits the same session.

### 12.2 Node server

**Stack:** Node.js, `node-oracledb` in **Thin mode** (pure JavaScript, no Oracle client install), the `ws` package for WebSockets, and a static file server for the client.

**On WebSocket connect:**

1. Read `{ "type": "hello", "world_id": 1, "player_id": 7 }` from the browser.
2. Open a connection with `oracledb.getConnection` (**not** a pool).
3. Call `pc_engine.init_session(world_id, player_id)`. This loads the world (target ≤ 3 s).
4. Reply `{ "type": "ready", "width": 640, "height": 360 }`.

**On each input message:**

1. If no tick is running, run one now.
2. If a tick **is** running, **merge** into a pending input: keep the latest `keys`, `held` and `seq`; **add** `mdx` and `mdy`; **OR** the click flags. Run it as soon as the current tick returns.
3. **The tick call:** an anonymous block calling `pc_engine.tick` with the 7 input values plus p\_dt (NULL in play) as IN binds and the frame as an **OUT bind of type `oracledb.BUFFER`, `maxSize` 1,200,000** (above the 1.15 MB worst case from Section 9.1).
4. Send the Buffer to the browser as one binary WebSocket message.

> **Confirm the BLOB bind in B6.** Binding a BLOB OUT parameter as a Buffer reads the whole LOB inside the call. If that misbehaves with our reused temporary BLOB, bind it as a LOB object instead and read it before the next tick.

**Errors:**

| Error | Meaning | Action |
| --- | --- | --- |
| ORA-04068, ORA-04061, ORA-04065 | Package state was discarded (someone recompiled) | Call `init_session` again, then retry the tick **once** |
| Connection lost | Database restarted or network dropped | Send `{ "type": "error" }`, close the socket; the browser reconnects |
| Anything else | Bug | Log it with the input that caused it, send an error message |

**On WebSocket close:** call `pc_engine.shutdown` (saves the player and commits), then close the connection.

**Logging:** every 5 seconds, log p50 and p95 of tick call time, plus the averages of `render_us` and `pack_us` read from frame headers.

### 12.3 Lockstep frame pacing

In the browser's `requestAnimationFrame` loop:

1. If a frame has arrived, decode and draw it (Section 9.3).
2. If **no input is in flight** and at least 1000 ÷ `TARGET_FPS` ms (41.7 ms) have passed since the last send, send the next input.

*Why not send inputs faster and pipeline?* One database session runs one call at a time. Extra inputs would only queue up, adding delay without adding frames. Lockstep keeps input lag at **one round trip plus one tick**.

### 12.4 Browser client

| Part | Job | Details |
| --- | --- | --- |
| **Input** | Track keys and mouse | `keydown`/`keyup` → bitmask (Section 10.1). **Pointer Lock** on canvas click; sum `movementX/Y` between sends. `mousedown` button 0 → `lclick`, button 2 → `rclick`. Block the context menu |
| **Hotbar** | Choose `held` | Keys 1–9 and 0 → stone, dirt, grass, sand, log, leaves, planks, cobblestone, brick, snow (ids 2, 3, 4, 5, 7, 8, 9, 10, 11, 12) |
| **Decoder** | Frame → pixels | Section 9.3 |
| **Palette** | Build `pal32` | Section 9.4; recompute for day/night and effects (9.5) |
| **Renderer** | Show the image | Hidden 640 × 360 canvas → scaled visible canvas, smoothing off |
| **HUD** | Debug overlay | fps, round trip, `render_us`, `pack_us`, runs per frame, position, target block and face |
| **Crosshair** | Aim point | Drawn by the browser at the screen centre. **Not** rendered by PL/SQL |
| **Connection** | Stay connected | Reconnect with back-off (1 s, 2 s, 4 s, max 10 s); resend `hello` |

Tell binary frames from control messages by type: `ArrayBuffer` is a frame, `string` is JSON.

### 12.5 Repository layout

| Folder | Contents |
| --- | --- |
| `db/schema/` | Table definitions and the install script |
| `db/packages/` | One spec (`.pks`) and body (`.pkb`) per package from Section 5.7 |
| `db/bench/` | Milestone 0 benchmarks B1–B5 |
| `db/tests/` | utPLSQL unit tests (Section 15) |
| `server/` | Node: WebSocket relay, Oracle session handling, static files |
| `client/` | HTML page, decoder, palette, input, HUD |
| `tools/` | Frame recorder and replayer for tests (Section 15) |

## 13. PL/SQL implementation rules

Most of the speed comes from **a handful of rules about types and compilation**. Break one inside the render loop and the frame budget is gone. Every rule below has bitten someone before.

### 13.1 Compilation

| Rule | Why | How |
| --- | --- | --- |
| **Compile every package natively** | Machine code instead of interpreted bytecode | `ALTER SESSION SET PLSQL_CODE_TYPE = NATIVE` before creating packages. Check `USER_PLSQL_OBJECT_SETTINGS` shows `NATIVE` |
| **Optimiser level 3 for hot packages** | Lets the compiler inline small helpers | `PLSQL_OPTIMIZE_LEVEL = 3` on `pc_render`, `pc_frame`, `pc_phys`. Add `PRAGMA INLINE(name, 'YES')` on calls to tiny helpers like the row rounding R(y) |
| **Install script sets both** | So nobody forgets after a recompile | The install script runs the two `ALTER SESSION` lines before any `CREATE` |

### 13.2 Types

| Rule | Why | Example |
| --- | --- | --- |
| **Integers in hot code: `SIMPLE_INTEGER`** | No null checks, no overflow checks | Loop counters, cell coordinates, row numbers |
| **Floats in hot code: `BINARY_DOUBLE`** | Hardware maths | Depths, rows, ray directions |
| **Never `NUMBER` in hot code.** Also never `INTEGER`: **it is a `NUMBER` subtype** | Software decimal maths, many times slower (B2 measures how much) | `l_t INTEGER` in the DDA loop silently kills speed |
| **Write float literals with a `d` suffix** | A plain `0.5` is a `NUMBER` literal and forces a conversion every time | `0.5d`, `1.62d`, `320d` |
| **`FLOOR` before assigning a float to an integer** | Assigning 2.7 to an integer variable **rounds to 3**; it does not truncate | `l_mx := FLOOR(l_ex);` never `l_mx := l_ex;` |
| **Keep coordinates ≥ 0** | `MOD(-1, 256)` is −1, and `TRUNC` rounds toward zero | Section 5.1 guarantees this |

### 13.3 Collections

| Rule | Why |
| --- | --- |
| **Pick the type B3 says is fastest** | Associative arrays, nested tables and VARRAYs differ in speed and memory |
| **Nested tables and VARRAYs start at index 1** | If one wins B3, add 1 to every index from Section 5.3 and 5.4. Associative arrays can start at 0 |
| **Never read an element that was not set** | A missing associative-array element raises `NO_DATA_FOUND`. Exceptions are slow, and they hide bugs. Fill every index at load |
| **Size fixed collections once** | Nested tables: one `EXTEND(n)` at load. Never `EXTEND` inside the tick |

### 13.4 Inside the tick

| Rule | Why |
| --- | --- |
| **No SQL in the render or physics loops** | Every SQL statement is a switch between the PL/SQL and SQL engines. The only SQL in a tick is the edit `UPDATE`/`INSERT` (Section 11.5) |
| **Copy hot package variables into locals** before the column loop | Cheap insurance against slower global access. Camera values (f, h, e\_y, F, R) become locals |
| **No exceptions as control flow** | Raising and catching is far slower than an `IF` |
| **No `DBMS_OUTPUT` in loops** | It buffers text in memory every call. Use the header timing fields instead |
| **No bit operators except `BITAND`** | PL/SQL has no shift, OR or XOR. Use `TRUNC(v / 256)` and `MOD(v, 256)` |

### 13.5 Timing and memory

- **Microsecond timing:** take two `SYSTIMESTAMP` values. Their difference is an `INTERVAL DAY TO SECOND`. Microseconds = (`EXTRACT(MINUTE …)` × 60 + `EXTRACT(SECOND …)`) × 1,000,000. Ticks never last a minute, so ignoring hours is safe.
- **Session memory:** `session pga memory` from `V$MYSTAT` joined to `V$STATNAME` (needs the grant in Section 4).
- **The 2 GB ceiling** covers the database's own memory **plus** every session. One player's world must stay well under it. B3 tells us how much a million-element collection costs.

### 13.6 Naming

| Prefix | Meaning | Example |
| --- | --- | --- |
| `pc_` | Package or table name | `pc_render`, `PC_COLUMN` |
| `g_` | Package-level (global) variable | `g_blocks`, `g_span_n` |
| `l_` | Local variable | `l_side_x` |
| `p_` | Parameter | `p_seq` |
| `c_` | Constant | `c_far`, `c_max_spans` |
| `t_` | Type | `t_int_tab` |

## 14. Configuration reference

Every tunable value in one place. Each setting lives in one of three spots:

- **Runtime:** a row in `PC_CONFIG`, read at `init_session`. Change it, reconnect, done.
- **Compile:** a constant in `pc_const`. Changing it means recompiling, and usually a new world.
- **Client:** a value in the browser's config file.

### 14.1 Rendering

| Setting | Lives in | Valid values | Default | Example | What it changes |
| --- | --- | --- | --- | --- | --- |
| `SCREEN_W` | Runtime | Multiple of 16, 160–640 | 640 | 320 | Number of screen columns, so roughly the render cost |
| `SCREEN_H` | Runtime | 90–360, keep 16:9 with W | 360 | 180 | Rows per column |
| `FOV_H_DEG` | Runtime | 60–110 | 90 | 75 (gives f = 417) | Field of view. Narrower = zoomed in |
| `FAR` | Runtime | 16–96 blocks | 48 | 32 | View distance. The biggest single cost lever |
| `FOG_START` | Runtime | 0 to `FAR` − 3 | 24 | 16 | Where fog band 1 begins |
| `PITCH_LIMIT_DEG` | Runtime | 0–45 | 35 | 45 | How far up/down you can look. Above 35 looks stretched |
| `EARLYOUT_EVERY` | Runtime | 1–16 cells | 4 | 2 | How often early-out (c) is checked |
| `T_NEAR` | Compile | 0.01–0.2 | 0.05 | 0.1 | Near clamp for depth |
| `MAX_SPANS` | Compile | 8–32 | 16 | 24 | Span slots per column. Changes memory and the span stride |

### 14.2 World and terrain

| Setting | Lives in | Valid values | Default | Example | What it changes |
| --- | --- | --- | --- | --- | --- |
| `WORLD_X`, `WORLD_Z` | Compile | 64–256 | 128 | 64 | World width and depth. Memory grows with the square |
| `WORLD_Y` | Compile | 64 only in v1 | 64 | — | Height. Fixed because `PC_COLUMN` is RAW(64) |
| seed | `PC_WORLD` row | 1 – 2,147,483,646 | — | 1337 | Which world you get |
| `GEN_PHASE` | Runtime (at generation) | 1 or 2 | 1 | 2 | 2 adds the 3D density pass (arches) |
| `SEA_LEVEL` | Runtime (at generation) | 1–62 | 20 | 16 | Water fills below this |
| `SNOW_LINE` | Runtime (at generation) | 1–63 | 44 | 38 | Top blocks this high become snow |
| `TERRAIN_BASE` | Runtime (at generation) | 1–62 | 24 | 30 | Average ground height (B) |
| `TERRAIN_AMP` | Runtime (at generation) | 0–40 | 16 | 24 | Hill height (A). 0 = flat world |
| `TERRAIN_FREQ` | Runtime (at generation) | 1/256 – 1/8 | 1/64 | 1/32 | Hill size (F). Bigger number = smaller, busier hills |
| `TERRAIN_OCTAVES` | Runtime (at generation) | 1–8 | 4 | 6 | Layers of detail (O) |
| `TERRAIN_LACUNARITY` | Runtime (at generation) | 1.5–3.0 | 2.0 | 2.5 | Frequency step per octave (L) |
| `TERRAIN_GAIN` | Runtime (at generation) | 0.2–0.8 | 0.5 | 0.6 | Strength step per octave (g). Higher = rougher |
| `SQUASH` | Runtime (at generation) | 2–32 | 8 | 12 | Phase 2 only. Higher = wilder overhangs |
| `DENSITY_FREQ_XZ` | Runtime (at generation) | 8–128 | 32 | 48 | Phase 2 horizontal feature size |
| `DENSITY_FREQ_Y` | Runtime (at generation) | 8–128 | 24 | 16 | Phase 2 vertical feature size. Lower = taller, thinner |

### 14.3 Player and physics

| Setting | Lives in | Valid values | Default | Example | What it changes |
| --- | --- | --- | --- | --- | --- |
| `MOUSE_SENS` | Runtime | 0.0005–0.01 rad/px | 0.0025 | 0.004 | Turn speed |
| `WALK_SPEED` | Runtime | 1–10 blocks/s | 4.3 | 5 | Normal speed |
| `SPRINT_SPEED` | Runtime | 1–15 blocks/s | 5.6 | 7 | Speed with Ctrl |
| `SNEAK_SPEED` | Runtime | 0.5–5 blocks/s | 1.3 | 1 | Speed with Shift |
| `GRAVITY` | Runtime | 5–60 blocks/s² | 28 | 20 | Fall acceleration (g) |
| `JUMP_HEIGHT` | Runtime | 0.5–3 blocks | 1.25 | 2 | Jump apex. Jump speed is √(2 × g × height) |
| `TERMINAL_VEL` | Runtime | 10–59 blocks/s | 40 | 30 | Max fall speed. **Must stay below 60** so a 1/60 s sub-step moves less than one block |
| `MAX_DT` | Runtime | 0.05–0.25 s | 0.1 | 0.2 | Longest time one tick may simulate |
| `REACH` | Runtime | 1–8 blocks | 5 | 4 | How far you can break and place |
| `SUBSTEP` | Compile | 1/60 s | 1/60 | — | Physics step. Tied to the `TERMINAL_VEL` rule |

### 14.4 Saving

| Setting | Lives in | Valid values | Default | Example | What it changes |
| --- | --- | --- | --- | --- | --- |
| `COMMIT_INTERVAL_S` | Runtime | 0–30 s (0 = every edit) | 2 | 5 | Max edits lost in a crash vs commit cost per frame |
| `SAVE_INTERVAL_S` | Runtime | 1–300 s | 10 | 30 | How often the player position is saved |

### 14.5 Client and middleware

| Setting | Lives in | Valid values | Default | Example | What it changes |
| --- | --- | --- | --- | --- | --- |
| `TARGET_FPS` | Client | 1–60 | 24 | 30 | Lockstep send rate cap |
| `TIME_OF_DAY` | Client | 0.0–1.0 (0 = midnight, 0.5 = noon) | 0.5 | 0.8 | Palette blend for day/night |
| `DEBUG_HEATMAP` | Client → sent with `hello` | true / false | false | true | Server paints walk-length heat map (Section 9.5) |
| `FRAME_MAX_BYTES` | Middleware | ≥ 1,200,000 | 1,200,000 | 2,000,000 | Size of the frame OUT bind |
| `RECONNECT_MAX_S` | Client | 1–60 s | 10 | 30 | Longest reconnect back-off |

## 15. Testing strategy

PL/SQL is tested with **utPLSQL v3**; the browser decoder with Node's built-in test runner. The two most valuable tests are **T-R1** (every pixel painted exactly once) and **T-R3** (golden frames), because renderer bugs are otherwise only visible as flickering pixels.

### 15.1 Deterministic replay

Tests need the same input to give the same frame every time. Two things make that possible:

- **`pc_engine.tick` takes an optional `p_dt` override** (seconds). In play it is NULL and dt is measured. In tests and replay it is fixed, usually 1/24.
- **`tools/` holds a recorder and a replayer.** The recorder saves the seed and every input message to a file. The replayer feeds them back through the same Node code with a fixed dt and saves every frame.

### 15.2 Test list

| ID | Area | What it checks | How | Passes when |
| --- | --- | --- | --- | --- |
| T-N1 | Noise | Same seed, same world | Generate twice in two sessions; compare permutation tables and 1,000 sample heights | Identical |
| T-N2 | Noise | 2D output range | 1 million samples of noise2 | Min and max within ±1.05; mean within ±0.02. Adjust the scale factor (Section 6.2) until true |
| T-N3 | Noise | 3D output range | Same as T-N2 for noise3 | Same |
| T-N4 | Noise | Smoothness | 10,000 pairs 0.001 apart | Every difference below 0.01 |
| T-W1 | World | Index maths | idx → (x, y, z) → idx for every block | Round trip is exact |
| T-W2 | World | Span builder | Fixed columns: plains, arch, 64 alternating materials | Expected spans; the 64-stripe column overflows into span 16 as described in 5.4 |
| T-W3 | World | Save and load | Generate, save, load in a fresh session | Block checksums identical |
| **T-R1** | Renderer | **Every row painted exactly once** | 100 random camera poses | In every column, run lengths sum to the height and no two runs overlap |
| T-R2 | Renderer | Coverage list | Feed the fills from the 8.5 example | Exactly the runs in that table |
| **T-R3** | Renderer | **Golden frames** | 5 fixed poses on seed 1337 | Byte-identical to stored frames. When a change is intended, regenerate them on purpose and review the images |
| T-R4 | Renderer | No fisheye | Flat wall at perpendicular depth 10 across the whole view | The wall's top row is the same in every column |
| T-R5 | Renderer | Early-outs are safe | Render 100 poses with early-outs on, then off | Identical frames |
| T-P1 | Physics | Landing | Drop from y = 40 onto flat ground | Feet end 0.001 above the top; `on_ground` true; never inside a block at any sub-step |
| T-P2 | Physics | No tunnelling | Fall at terminal speed onto a one-block slab | Lands on the slab |
| T-P3 | Physics | Wall slide | Walk diagonally into a wall | Keeps moving along the wall |
| T-P4 | Physics | Jump height | Default settings | Clears a 1-block step, not a 2-block step |
| T-I1 | Interaction | Raycast | The 11.1 example | Hits (67, 23, 64), face 3, prev (67, 24, 64) |
| T-I2 | Interaction | No self-burial | Place into the player's own cell | Rejected |
| T-I3 | Interaction | Bedrock | Break bedrock | Nothing changes |
| T-F1 | Frame | Decoder | The example column bytes from 9.1 | Expected pixels (Node test) |
| T-F2 | Frame | Header | PL/SQL writes known header values; the JS decoder reads them | Same values |
| T-PERF1 | Performance | Regression guard | Replay a recorded 60 s flythrough | `render_us` p95 ≤ 20 ms, and no more than 10% slower than the last run |

### 15.3 When to run what

| When | Run |
| --- | --- |
| Every change to a package | That package's utPLSQL suite |
| Before merging anything into the renderer | T-R1 to T-R5 and T-PERF1 |
| After any change to the frame format | T-F1, T-F2, and bump `version` in the header |

## 16. Milestones and team split

Eight milestones in **two lanes**. **M0 gates everything.** After it, the **engine lane** (world, renderer, arches) and the **platform lane** (plumbing, movement, interaction, polish) run side by side. **M3, the renderer, is the critical path**: it is the riskiest work and everything visible depends on it.

&#91;embedded content: Milestones · 2 lanes, 8 milestones, test gates\]

Each box lists what it needs from the other lane and the tests that close it. A milestone is done when its gate passes, not when the code is written.

### 16.1 Agree these three interfaces on day one

Both lanes code against them, so changing one later means changing both lanes. Each gets a version number and a review before it changes.

1. **Frame format v1** (Section 9.1)
2. **`pc_engine` API** (Section 3.2)
3. **Input message** (Section 10.1)

### 16.2 Who owns what

| Lane | Owns | Benchmarks |
| --- | --- | --- |
| **Engine (owner A)** | `pc_noise`, `pc_world`, `pc_render`, `pc_frame` | B1–B4 |
| **Platform (owner B)** | `server/`, `client/`, `tools/`, `pc_phys`, `pc_engine` glue | B5–B6 |

### 16.3 Onboarding: what to read, in order

1. **Everyone:** Sections 1, 2 and 3. That is the what, the words and the shape.
2. **Engine lane:** then 5, 6, 7, 8, 9 and 13.
3. **Platform lane:** then 9, 10, 11, 12 and 13.
4. **Then run Milestone 0 on your own machine** (Section 4). It is the fastest way to get Oracle, native compilation and the timing tools working, and it produces numbers we need anyway.

## 17. Risks and open questions

The biggest risk is simple: **PL/SQL may be too slow for 640×360 at 24 fps**. Milestone 0 exists to find out in days, not weeks. Every risk below has a fallback that keeps the project alive.

### 17.1 Risks

| Risk | Likelihood | Impact | Early warning | Fallback |
| --- | --- | --- | --- | --- |
| **Renderer too slow** | Medium | High | B4 over 15 ms | 320×180, then `FAR` 32 (Section 4 decision rule) |
| **Packing or LOB calls too slow** | Medium | Medium | B5 over 5 ms | Return a collection of `RAW(32767)` chunks instead of a BLOB |
| **World does not fit in memory** | Low | High | B3 over 100 MB per million elements | 96 × 96 world, or two blocks per element (a × 16 + b) |
| **Benchmarks run under emulation** | Medium | High | Numbers far worse than expected on an Apple Silicon Mac | Check the Oracle container image is **native arm64**, not x86 under emulation. Emulated numbers are meaningless. Benchmark on the machine you will demo on |
| **Sheared look feels wrong** | Medium | Low | Playtesters complain | Lower `PITCH_LIMIT` to 30°, or accept 45° with more stretch |
| **Cannot click blocks at your feet** | Certain | Low | — | Accept for v1 (Section 7.5) |
| **Recompile wipes the running game** | Certain during development | Low | ORA-04068 in Node logs | Auto re-init in the middleware (Section 12.2) |
| **Same player opens two tabs** | Low | Medium | Two sessions saving the same columns | Node refuses a second `hello` for a player who is already connected |
| **Floating rocks in phase 2** | High | Low | Visible islands | Accept, or a flood-fill clean-up pass (Section 6.6) |
| **Water and leaves are opaque and solid** | Certain | Low | — | Accepted for v1; real water needs transparency |

### 17.2 Open questions

- [ ] Which collection type wins B3, and how much memory does a million elements cost?
- [ ] Final resolution: 640×360 or 320×180? Decided by the Section 4 rule after Milestone 0.
- [ ] Who owns the engine lane and who owns the platform lane (Section 16)?
- [ ] Is a 35° pitch limit acceptable, or do we want 45°?
- [ ] Is a 128 × 128 world big enough, given `FAR` = 48 shows most of it from the centre?
- [ ] Should water become non-solid (swimming) after v1, before or after transparency?
- [ ] Multiplayer later: each session holds its **own** copy of the world, so edits do not reach other players. How should sessions share changes? (Out of scope for v1.)

### Sources

- [Oracle AI Database Free: licensing restrictions](https://docs.oracle.com/en/database/oracle/oracle-database/23/xeinl/licensing-restrictions.html) (CPU, RAM, data and installation limits)
