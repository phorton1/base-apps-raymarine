# navMate Build / Deploy Notes

Work-in-progress runbook for packaging navMate into an installable Windows
application that needs no Perl on the target machine. Captured as the build is
developed. Initially unlinked: not yet wired into the docs nav headers.


## Toolchain

- Cava Packager 2.0 (build 2.0.80.263) -- GUI at
  C:\Program Files (x86)\Cava Packager 2.0\bin\cavapackager.exe
  Single-instance app. Scans a Perl app and bundles a private ActivePerl 5.12
  (perl512.dll) plus wxWidgets 3.0 into Windows exe(s). Abandonware; the .cpkgproj
  project file is a SQLite database.
- Inno Setup 5 -- C:\Program Files (x86)\Inno Setup 5\ISCC.exe -- compiles the
  generated innosetup.iss into the user-facing installer exe.
- Dev Perl: C:\Perl (ActivePerl 5.12.4) -- the SAME version Cava bundles, so every
  XS module that works in dev is ABI-compatible with the packaged build.


## Project location

C:\base_dist\navMate\  (git-controlled; "initial commit" = the blank Cava New Project)

  cava20.cpkgproj      the project config -- a SQLite database. Readable, diffable,
                       and (with Cava closed) writable directly via DBD::SQLite.
  cava20/ cava20-temp/ cava20-logs/ installer/ release/   standard Cava dirs.


## Project setup (done)

Created via Cava "New Project":
    Project Name : navMate
    Project Path : C:\base_dist\navMate
    First Script : C:\base\apps\raymarine\apps\navMate\navMate.pm   (the wx GUI main)

Left as Cava set them:
    exec_type   = 2 (console subsystem -- a console window AND the wx GUI, i.e. the
                     dev experience; this is the v1 shape)
    perlpath    = C:/Perl/bin/perl.exe   (auto-detected)
    version     = 0.0.0.1
    project_class_id / executable class_id : freshly minted GUIDs (never edit by hand)

Config delta applied to cava20.cpkgproj (SQL, Cava closed; pre-edit backup + git baseline):
    config_values.appfolder        : MyApp   -> navMate
    config_values.copyright        :         -> Copyright (C) 2026 Patrick Horton
    local_config_values.extrapaths : (empty) -> C:/base
        (the @INC root, so Cava's scan resolves Pub:: and apps::raymarine::NET::*)
    include_module (force-include the runtime-loaded modules a static scan misses):
        DBD::SQLite       DBD/SQLite.pm
        JSON::PP          JSON/PP.pm
        threads           threads.pm
        threads::shared   threads/shared.pm


## v1 shape and key decisions

- v1 = ONE executable: navMate.exe, exec_type=2 (console + GUI in one app).
- A clean GUI-only second exe (CM-style: a setIsGUI wrapper script + guarding the
  console code) is deferred to public-release polish. Note: Cava's own IsGUI() does
  not link when packaged, so that path needs a hand-rolled isGUI flag (Pub has none).
- Database location: a prefs key, default $data_dir/navMate.db, seeded on first run;
  dev keeps C:/dat/Rhapsody/navMate.db via its own prefs file. (Source-seam work, a
  later phase.)
- Packaged-mode path detection: VERIFIED WORKING -- the Cava runtime sets $Cava::Packager::PACKAGED
  (a packaged run created Documents/raymarine + AppData/Local/Temp/raymarine). No Pub::Utils fix needed.
- Inline::C navMatch kernel: pure-Perl matcher when packaged for v1; a precompiled,
  bundled C kernel is a precondition of public release (34x Find speedup).


## Build steps

Commit policy: this file is the record of the in-between (iterating / broken) states;
git commits on C:\base_dist\navMate mark states where something actually WORKS. The
config delta above currently sits UNCOMMITTED in the working tree on top of the blank
"initial commit" -- intentionally. Do not commit intermediate config; iterate
Scan-and-Build until it builds and launches, then commit that as the first working
milestone.

1. Reopen Cava, confirm the config loaded.
2. Distribution -> Scan and Build Project. Read cava20-logs/build.log and scan.log for
   failures. Each missing runtime-loaded module becomes another include_module row;
   rebuild; repeat until it builds and launches. Record each state in this file.
3. Commit the first working build to git (the first real milestone).
4. (later) Inno installer setup, version/filename scheme, the source-seam path work,
   the packaged smoke test.


## Gotchas and lessons (captured as encountered)

- Cava launched off-screen once: saved window position left=-32000 / top=-32000 (the
  Windows "minimized window" sentinel). Fix: quit Cava, edit
  C:\Users\Patrick\AppData\Local\cava\cavapack\packager\conf\wxapp.config , section
  [CF::Packager::Form::MainWindow/position], set left/top to on-screen values, relaunch.
- cavaconsole.exe is a runtime diagnostic console, NOT a headless builder. The build is
  a GUI operation (Distribution -> Scan and Build Project).
- The .cpkgproj is the single source of truth and it is SQLite. To compare projects,
  dump and diff the DBs directly -- Cava is single-instance, so window-by-window
  comparison is unnecessary.

## Iteration log

### Build 1 (0.0.0.2) -- 2026-06-10
- Scan + Build: clean on the first try. Produced release/navMate/ (navMate.exe +
  cpfworkrt/perl512.dll runtime + wx DLLs) plus the SFX navmate-mswin-x86-0-0-0.exe.
  Only the benign Cava-on-modern-Windows OS-signature notice; no real errors. Build
  auto-bumped to 0.0.0.2. (No Inno installer: installer.config doinstaller / installer_capable
  are 0 -- a deferred step.)
- Launch (release/navMate/bin/navMate.exe): the PACKAGED path detection WORKS -- it created
  /Users/Patrick/AppData/Local/Temp/raymarine and /Users/Patrick/Documents/raymarine (the
  packaged branch), proving the Cava runtime sets $Cava::Packager::PACKAGED. It loaded the
  qualified apps::raymarine::NET::* stack (b_sock opened its UDP socket), then DIED at
  navMate.pm line 31, "use n_defs;" -- Can't locate n_defs.pm in @INC.
- Root cause: navMate loads its locals by BARE name (use n_defs / n_utils / navDB ...),
  which in dev resolve only via "." (cwd = the navMate folder). That folder was not in
  Cava's scan @INC (extrapaths was just C:/base), so the scanner never found or packed
  them. The qualified NET modules resolved via C:/base and packed fine.

### Config changes applied for Build 2 (SQL, Cava closed, backup taken)
- extrapaths: C:/base  ->  C:/base;C:/base/apps/raymarine/apps/navMate
  (so the scan finds the bare-name navMate locals; ";"-separated. Precedent: CM uses
  C:/base;C:/base/MBE/cmManager for the same reason.) This is the chosen fix rather than
  refactoring to qualified names, because two files -- e80Config.pm and e80ScreenGrab.pm --
  MUST remain unqualified (reasons beyond this repo), so the bare-name convention is
  permanent and the scan path is the correct accommodation.
- codemask: 2 -> 1 (config_values + the navMate.pm script row) = "Plain Text Perl Code"
  instead of "Masked", matching buddy. The source is open on GitHub; masking adds nothing.
- Left as-is: script "location" 32 ("Virtual Script") -- navMate.pm packed there and ran
  fine to line 31, so it is not the n_defs cause.

Next: reopen Cava, re-run Scan + Build, confirm n_defs (and the rest of the bare-name
family) now pack, then re-launch.

### Build 2 -- 2026-06-10  (THE FIRST WORKING BUILD)
- Re-scan + Build with the navMate folder on extrapaths: the bare-name family (n_defs,
  n_utils, navDB, navServer, nmFrame, ... including e80Config.pm + e80ScreenGrab.pm) now
  scans AND packs. Clean build, "Release Creation Complete", only the benign utf8/unicore
  notices.
- Launch (release/navMate/bin/navMate.exe): navMate CAME UP and ran end-to-end:
    * prefs loaded from /Users/Patrick/Documents/raymarine/navMate.prefs (PACKAGED data dir)
    * Win32::Console opened (the exec_type=2 console works)
    * DBD::SQLite WORKS: navDB::openDB opened the DB, schema 12.0, all 7 tables present
    * HTTP server started on port 9883
    * talked to a REAL E80 (RAYDP IDENT E80_2), started WPMGR/FILESYS/TRACK, queried
      waypoints/routes/groups, and pulled real tracks (2006-01-11-SanD, BOCAS1-001).
  => A bundled, Perl-free exe doing live E80 protocol + SQLite. Phase 1 (build+launch) DONE.
- KNOWN reach-backs still to fix (the seam / Phase 3 -- both visible in the launch log,
  both "work" only because the source exists on this machine):
    * DB: navDB::openDB(C:/dat/Rhapsody/navMate.db) -- hardcoded real DB. Re-home to a prefs
      key, default $data_dir/navMate.db, seed-on-first-run; dev overrides via its prefs file.
    * _site: HTTP_DOCUMENT_ROOT = C:\base\apps\raymarine\apps\navMate/_site -- the served
      website reaches into SOURCE (_site is not bundled). Re-home to $resource_dir + bundle _site.
- Minor/benign: the E80 IDENT name field printed garbled (pre-existing non-ASCII encoding,
  not a packaging issue). The Inline::C / Find path was not exercised at startup, so the
  C-kernel packaging question (pure-Perl-when-packaged) is still open for when Find runs.
- This is the "first thing that actually works" milestone -> a good point to commit
  base_dist/navMate (the working build config).

## Seam -- packaged-vs-dev divergences (running list)

All the same flavor: config that should differ between the dev and installed versions,
solved by one mechanism (env-dependent defaults keyed on $Cava::Packager::PACKAGED,
surfaced through the per-environment prefs file). None block the build/launch.

1. DB path  [VERIFIED 2026-06-10 -- packaged run]: was hardcoded
   C:/dat/Rhapsody/navMate.db -> now the DATABASE_PATH pref. Packaged default
   $data_dir/navMate.db (My Documents); dev default stays the live /dat database.
2. _site (served website)  [pending]: HTTP_DOCUMENT_ROOT reaches into source
   $app_dir/_site -> re-home to $resource_dir AND bundle _site into the package.
   The same re-home covers sym_catalog (and _Inline) -- $app_dir is the catch-all
   source root, so the whole resource family moves together (see other reach-backs).
3. HTTP port  [VERIFIED 2026-06-10 -- packaged run]: dev and installed both
   bound 9883 (could not coexist). Now the HTTP_PORT pref: dev 9883, packaged 9873.
   ServerBase already honors an HTTP_PORT pref, so the override came for free.

Other reach-backs found in the same audit (still to do):
- nmE80DirectOps.pm: C:/dat/Rhapsody/E80Configs and .../E80Screens hardcoded (-> $data_dir).
- nmFrame.pm: the Commit/Revert "navMate.db to git" ops shell out to git -C C:/dat/Rhapsody
  -- a dev-only feature; gate it off (or re-derive the dir) when the DB is not under git.
- navMatchC.pm: _Inline under $app_dir -- the Inline::C-when-packaged question (open).
- navServer.pm openMapBrowser: launches "firefox" by name -- fragile on a user machine;
  a public build should fall back to the default browser. (Port now follows the server.)

### Seam pass -- 2026-06-10  (items a + b: DB path + HTTP port)
- navPrefs.pm: added DATABASE_PATH and HTTP_PORT prefs with $Cava::Packager::PACKAGED-
  dependent defaults; init_prefs now also writes a barebones, human-editable navMate.prefs
  on first run (never clobbers an existing file) so DATABASE_PATH/HTTP_PORT are visible and
  editable without guessing key names.
- navDB.pm: openDB / _db_params resolve the path via _dbPath() = getPref(DATABASE_PATH),
  read at run time (after init_prefs) and cached. $NAVMATE_DATABASE remains the dev default.
- navServer.pm: port resolved via _serverPort() = getPref(HTTP_PORT); startNavMateServer,
  the server ctor params, and openMapBrowser all use it. The _site client uses relative
  URLs, so the Leaflet map follows the bound port automatically.
- Net effect: a packaged navMate defaults to its own DB (My Documents) and its own port
  (9873), so it can run side by side with the dev build and never touches the live database.
- EOL: navMate.pm is CRLF; every other navMate .pm edited here is LF. Edits matched per file.
- VERIFIED 2026-06-10 (packaged release/navMate/bin/navMate.exe, clean Documents/raymarine):
  seeded navMate.prefs (explicit DATABASE_PATH + HTTP_PORT=9873); openDB created a FRESH
  empty schema-12.0 DB at Documents/raymarine/navMate.db (NOT the live /dat DB); server bound
  PORT(9873); live E80 still worked (RAYDP/WPMGR/FILESYS/TRACK, pulled 2006-01-11-SanD,
  BOCAS1-001). NB the same run logged HTTP_DOCUMENT_ROOT = ...apps/navMate/_site -- i.e. the
  served site still reaches into SOURCE, so item 2 (_site -> $resource_dir + bundle) is the
  real blocker before the package can run on a machine without the dev tree.

## Known limitations / deeper iceberg (public-install scoping)

- My Documents subfolder name: packaged $data_dir is My Documents/raymarine (from $appGroup
  in NET/a_utils.pm, shared with shark). "raymarine" is presumptuous as a worldwide My
  Documents folder; revisiting it is a shared-a_utils decision, deferred for now. Because the
  packaged DB/data defaults derive from $data_dir, renaming that folder later needs no rework
  in this seam.
- e80Config / e80ScreenGrab: these two features are NOT cleanly shippable in a public v1.
  They depend on (1) a separate hardcoded port [branching it is out of scope for this repo
  right now], (2) a Windows firewall hole the user must open (which the install would need to
  document), and (3) CUSTOM E80 FIRMWARE running on the device. For the public installable
  these are "advanced / requires custom firmware" features, not baseline.

## Version control

- This raymarine repo: the only change for this milestone is the addition of this file,
  docs/notes/build.md (initially unlinked from the docs nav headers).
- base_dist/navMate is a SEPARATE, LOCAL git repo (currently non-public, not on GitHub).
  Its .gitignore -- identical to base_dist/buddy and base_dist/cm -- ignores EVERYTHING
  except .gitignore and cava20.cpkgproj:

      # Ignore everything
      *
      # But not these files...
      !.gitignore
      !cava20.cpkgproj

  So ONLY the SQLite project file (cava20.cpkgproj) is tracked -- it IS the project / the
  single source of truth. cava20/, cava20-temp/, cava20-logs/, installer/, release/ (and the
  built exe) are all regenerable by a Scan-and-Build and are intentionally untracked, so the
  repo stays lean and binary-free.
- Gotcha + fix (2026-06-10): the repo's FIRST git init + commit was done BEFORE the
  .gitignore existed, so Cava's data files (cava20/msw/scan.data, cava20-temp/subscan.data,
  cava20-temp/cache/.cache) got tracked -- and .gitignore cannot evict already-tracked
  files. Resolved by re-initializing the repo clean (old .git moved aside to temp), leaving
  a single commit tracking only .gitignore + cava20.cpkgproj. LESSON: add the .gitignore
  BEFORE the first commit (buddy/cm did).
