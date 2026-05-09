# DBNAV - Navigation Field Database

**[Home](../../docs/readme.md)** --
**[NET](readme.md)** --
**[RAYNET](RAYNET.md)** --
**[RAYDP](RAYDP.md)** --
**[WPMGR](WPMGR.md)** --
**[TRACK](TRACK.md)** --
**[FILESYS](FILESYS.md)** --
**DBNAV** --
**[shark](../../apps/shark/docs/shark.md)** --
**[navMate](../../apps/navMate/docs/readme.md)** --
**[Cables](ethernet_cables.md)**

Two related services provide access to the E80's navigation field database,
both using service_id **16** (0x10, shown as `1000` in hex streams):

- **Database** - TCP port **2050**, queried for field definitions and subscriptions.
  Implemented in `d_DB.pm`.
- **DBNAV** - multicast **224.30.38.195:2562**, broadcasts live field values when
  the E80 is underway. Implemented in `d_DBNAV.pm`.

DBNAV is, in effect, the broadcast arm of Database. The same parser handles both.

## Database Service (port 2050, TCP)

### Commands

| Hex  | Name          | Description                                      |
| ---- | ------------- | ------------------------------------------------ |
| 0x00 | DB_CMD_UUID   | Keep-alive / field lookup by UUID                |
| 0x01 | DB_CMD_DEF    | Request / receive a field definition             |
| 0x02 | DB_CMD_FIELD  | Request / receive a field value                  |
| 0x03 | DB_CMD_EXISTS | Check whether a field ID exists                  |
| 0x04 | DB_CMD_NAME   | Request / receive a field name string            |
| 0x05 | DB_CMD_QUERY  | Query with seq + fid                             |

Successful replies carry the signature `04000000` following the sequence number
(different from the FILESYS/WPMGR success signature `00000400`).

### Known Field IDs

The following FIDs are identified in `d_DB.pm`. Many more exist - `NET/docs/reference/fids.txt`
contains raw buffer data for unidentified FIDs captured from RNS database startup.

**Navigation:**

| FID  | Name            | Type / Units                                   |
| ---- | --------------- | ---------------------------------------------- |
| 0x03 | SPEED           | Speed through water, cm/s                      |
| 0x04 | SOG             | Speed over ground, cm/s                        |
| 0x09 | DEPTH           | Depth                                          |
| 0x17 | HEADING         | Heading (magnetic)                             |
| 0x1a | COG             | Course over ground                             |
| 0x44 | LATLON          | Latitude / longitude                           |
| 0x93 | NORTHEAST       | Northing / easting (Mercator)                  |

**Wind:**

| FID  | Name              | Type / Units                                 |
| ---- | ----------------- | -------------------------------------------- |
| 0x58 | WIND_SPEED_APP    | Apparent wind speed, dm/s                    |
| 0x59 | WIND_ANGLE_APP    | Apparent wind angle, 0-360deg relative to bow  |
| 0x5a | WIND_SPEED_TRUE   | True wind speed, dm/s                        |
| 0x5b | WIND_ANGLE_TRUE   | True wind angle                              |
| 0x5c | WIND_SPEED_GND    | Ground wind speed, dm/s                      |
| 0x5d | WIND_ANGLE_GND    | Ground wind angle (E80 shows MAG despite "T" label) |

**Active Waypoint / Route:**

| FID  | Name        | Type / Units                                       |
| ---- | ----------- | -------------------------------------------------- |
| 0x66 | WP_HEADING  | Bearing to active waypoint                         |
| 0x69 | WP_ID       | Waypoint ID string (two decimal places ~ 60 ft precision) |
| 0x6a | WP_DISTANCE | Distance to active waypoint, meters                |
| 0xd0 | WP_TIME     | ETA to active waypoint, seconds                    |
| 0xd8 | WP_NAME     | Active waypoint name, string (15 chars)            |

**Engine / NMEA 2000:**

| FID  | Name           | Type / Units                                    |
| ---- | -------------- | ----------------------------------------------- |
| 0x21 | ENG_OIL_PRESS1 | Engine 1 oil pressure, millibars -> PSI          |
| 0x22 | ENG_OIL_TEMP1  | Engine 1 oil temperature, Kelvin/10             |
| 0x30 | ENG_RPM1       | Engine 1 RPM, raw word / 4                      |
| 0x32 | FUEL_LEVEL2    | Fuel level tank 2, word/250 -> 0-100%            |

**Fuel Level Notes:** The fuel level and capacity fields from the E80 do not follow
NMEA 2000 scaling conventions. The math is asymmetric and sparse - decoding both
tanks requires solving a system of equations. This has been implemented but the
details are intentionally left in the code (`d_DB.pm`) rather than documented here,
as the specifics are hardware-dependent.

## DBNAV Service (multicast 224.30.38.195:2562)

DBNAV is a thin multicast listener. It receives the same field value broadcasts
that Database publishes, decoded by the shared DB parser.

- Broadcasts begin when the E80 has a GPS fix and heading
- When underway, broadcasts arrive at high frequency (many packets per second)
- Field values expire via a TTL mechanism in `onIdle()` - stale values are cleared
- `getFieldValues()` returns the current `{field_values}` hash, keyed by FID

The multicast address 224.30.38.195 is specific to the test E80's IP (10.0.241.54).

## Raw FID Reference

`NET/docs/reference/fids.txt` contains raw buffer captures from RNS's database
enumeration session, including responses for FIDs not yet decoded. This file is
the primary source for future FID identification work.

---

**Next:** [shark](../../apps/shark/docs/shark.md)
