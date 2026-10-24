# PL/Craft: Oracle on Fedora over a mobile hotspot

These instructions are for standard Fedora Workstation or Server. They have been checked against upstream documentation and the launcher passes Bash syntax validation; they have not been executed on your Fedora computer. Fedora Atomic variants may already include Podman and use a different package-management workflow.

Both computers must join the same hotspot and be allowed to communicate with each other. Use the Linux computer's Wi-Fi IPv4 address, not the phone's gateway address or an address inside the container. Traffic between the computers stays on the local Wi-Fi link; the image download needs internet access. A hotspot that isolates clients can block this connection; test it rather than assuming that sharing an SSID guarantees access.

On native Linux, Podman containers share the host Linux kernel, so no VM is required. For this project use the full Oracle Free image, then check native compilation explicitly with the supplied setup script.

## 1. Install on Linux

```bash
sudo dnf install -y podman
podman info
podman pull container-registry.oracle.com/database/free:latest
podman volume create plcraft-data
ip -4 -br address
```

The image automatically selects the host's supported native architecture. Do not force an Intel platform on an ARM computer. Podman does not need its API service or socket enabled for these commands. The named volume preserves your database after a container is removed.

## 2. Start a terminal-bound session

Save `plcraft-db-session-linux.sh` and `plcraft-setup.sql` on the Linux computer. The IP below is an example: replace it with the Wi-Fi IPv4 address reported above.

```bash
chmod +x plcraft-db-session-linux.sh
./plcraft-db-session-linux.sh 192.168.43.100
```

Enter a strong administrator password, and keep this terminal open. Use the same administrator password on later starts. Wait for `DATABASE IS READY TO USE!` before connecting. Oracle listens only on the supplied host IP, port 1521.

Ctrl-C, a normal terminal hangup, or a termination signal triggers shutdown. The launcher waits for Oracle to stop and removes the container; the named database volume remains. No automatic restart or boot service is configured. A shell trap cannot handle `kill -9`; if the launcher is forcibly killed, stop its container explicitly:

```bash
podman stop --time 60 plcraft-db
```

## 3. Create the application schema once

In a second Linux terminal, from the directory containing the supplied SQL file:

```bash
podman cp plcraft-setup.sql plcraft-db:/tmp/plcraft-setup.sql
podman exec -it plcraft-db sqlplus '/ as sysdba' @/tmp/plcraft-setup.sql
```

Choose a separate application password when prompted. The SQL creates `PLCRAFT` in `FREEPDB1`, grants schema development privileges plus access to `V_$MYSTAT` and `V_$STATNAME`, and checks that a procedure compiles and runs in NATIVE mode at optimization level 3. Run this setup only once; it intentionally fails if `PLCRAFT` already exists instead of replacing existing data. Your project's future installation scripts must also set `PLSQL_CODE_TYPE=NATIVE` and `PLSQL_OPTIMIZE_LEVEL=3` before compiling packages; these are session settings.

## 4. Allow the client if firewalld requires it

Inspect the firewall and identify the zone containing your Wi-Fi interface:

```bash
sudo firewall-cmd --state
sudo firewall-cmd --get-active-zones
```

If it is active and blocks this connection, replace `YOUR_WIFI_ZONE` with that zone and the example source IP with the Mac's current hotspot IPv4 address:

```bash
sudo firewall-cmd --zone=YOUR_WIFI_ZONE \
  --add-rich-rule='rule family="ipv4" source address="192.168.43.101/32" port port="1521" protocol="tcp" accept' \
  --timeout=2h
```

This adds a temporary allowance for two hours. It does not enable or disable firewalld, change SELinux settings, or replace the zone's other rules. Reapply it after expiry if needed. The database remains unreachable after its container stops, even while a firewall allowance exists.

## 5. Connect from the Mac

Test the port:

```bash
nc -vz -G 3 192.168.43.100 1521
```

Connection settings:

| Setting | Value |
| --- | --- |
| Host | Linux computer's hotspot IP, e.g. `192.168.43.100` |
| Port | `1521` |
| Service name | `FREEPDB1` (use service-name mode, not SID mode) |
| Username | `plcraft` |
| Password | Application password chosen during setup |

In your Node project's existing `oracledb.getConnection` call:

```js
const connection = await oracledb.getConnection({
  user: 'plcraft',
  password: process.env.PLCRAFT_DB_PASSWORD,
  connectString: '192.168.43.100:1521/FREEPDB1',
});
```

The Node driver uses Thin mode by default and does not require Oracle Instant Client. Keep one connection for the player's session, as specified in the design.

If the port test fails, first confirm that Oracle is ready and check the Linux firewall and published port (`podman port plcraft-db`). Some hotspots isolate connected clients; try another access point or a wired network if the two machines cannot communicate. Recheck both IP addresses after reconnecting to the hotspot.

## 6. Check shutdown

Press Ctrl-C in the first Linux terminal, wait for shutdown, then run:

```bash
podman ps --filter name=plcraft-db
```

It should show no running database container. The Mac's port test should fail after shutdown. Start a new session with the same launcher to reuse the saved database.

## 7. Run the game server on the Linux computer

Benchmark B6 measured the Node-to-Oracle round trip over the hotspot at p95 25.7 ms, against a 3 ms budget, while the PL/SQL itself took well under 1 ms (`db/bench/results.md`). Running Node next to Oracle takes the database calls off Wi-Fi; only the browser's input and frames still cross it.

On the Linux computer, check that `node -v` reports 22.9 or newer (`sudo dnf install -y nodejs`, or a current release from nodejs.org). Copy the project over from the Mac, without `node_modules`:

```bash
rsync -a --exclude node_modules --exclude .env ./ YOUR_USER@192.168.43.100:pl-craft/
```

Then on the Linux computer, in `~/pl-craft`, create `.env` and start the server. Use the hotspot address in the connect string: the launcher publishes Oracle only on that address, not on `localhost`.

```bash
npm ci
cat > .env <<'EOF'
PLCRAFT_DB_USER=plcraft
PLCRAFT_DB_PASSWORD=your-application-password
PLCRAFT_DB_CONNECT_STRING=192.168.43.100:1521/FREEPDB1
EOF
npm run db:bench   # B6 again, now without the Wi-Fi hop
npm start
```

`npm start` prints the address to open from the Mac, such as `http://192.168.43.100:8080`. If firewalld blocks it, allow the Mac the same way as in step 4, with `port="8080"` in place of `port="1521"`. The browser still crosses Wi-Fi, so check the frame rate in the game's stats (F3) on the actual network.

Sources: [Podman installation](https://podman.io/docs/installation), [Podman run](https://docs.podman.io/en/latest/markdown/podman-run.1.html), [Oracle container documentation](https://github.com/oracle/docker-images/tree/main/OracleDatabase/SingleInstance), [firewalld commands](https://firewalld.org/documentation/man-pages/firewall-cmd.html), [node-oracledb connections](https://node-oracledb.readthedocs.io/en/latest/user_guide/connection_handling.html).
