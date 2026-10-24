-- Tables (Section 5.6): the saved copy of every world. While playing, the world lives in package state.
-- IF NOT EXISTS: reinstalling never touches data. Changing a column here needs an explicit migration.
-- Each statement ends with a line holding only "/", so this file also runs as is in SQL*Plus or SQLcl.

-- PC_WORLDS, not Section 5.6's PC_WORLD: tables and packages share one namespace, and pc_world is the package.
create table if not exists pc_worlds (
  world_id    number(10) primary key,
  seed        number(10) not null check (seed between 1 and 2147483646),
  size_x      number(3) not null,
  size_y      number(3) not null,
  size_z      number(3) not null,
  gen_version number(5) not null,
  gen_params  json,
  created_at  timestamp default systimestamp not null
)
/

-- One row per world column. Byte y of blocks is the material at height y.
create table if not exists pc_column (
  world_id number(10) not null references pc_worlds,
  x        number(3) not null,
  z        number(3) not null,
  blocks   raw(64) not null,
  constraint pc_column_pk primary key (world_id, x, z)
)
/

create table if not exists pc_player (
  player_id number(10) primary key,
  world_id  number(10) not null references pc_worlds,
  name      varchar2(40) not null,
  px        binary_double not null,
  py        binary_double not null,
  pz        binary_double not null,
  yaw       binary_double not null,
  pitch     binary_double not null,
  held      number(2) not null check (held in (2, 3, 4, 5, 7, 8, 9, 10, 11, 12)),
  saved_at  timestamp not null
)
/

create table if not exists pc_edit_log (
  world_id  number(10) not null references pc_worlds,
  seq       number generated always as identity,
  x         number(3) not null,
  y         number(2) not null check (y between 0 and 63),
  z         number(3) not null,
  old_m     number(2) not null check (old_m between 0 and 15),
  new_m     number(2) not null check (new_m between 0 and 15),
  player_id number(10) references pc_player,
  at        timestamp default systimestamp not null,
  constraint pc_edit_log_pk primary key (world_id, seq)
)
/

-- Runtime settings (Section 14), read by pc_engine.init_session.
create table if not exists pc_config (
  name  varchar2(30) primary key,
  value number not null
)
/
