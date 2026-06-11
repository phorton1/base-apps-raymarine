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
2. _site + sym_catalog  [DONE 2026-06-10]: were under source $app_dir; moved to a
   dedicated repo resource folder apps/navMate/_res/{site,sym_catalog} (git mv, 54 pure
   renames), routed through $resource_dir (setStandardCavaResourceDir in n_utils), and the
   Cava resource_path set to .../_res so the whole tree bundles.  _Inline NOT moved -- that
   is the separate Inline::C-when-packaged item.
3. HTTP port  [VERIFIED 2026-06-10 -- packaged run]: dev and installed both
   bound 9883 (could not coexist). Now the HTTP_PORT pref: dev 9883, packaged 9873.
   ServerBase already honors an HTTP_PORT pref, so the override came for free.

Other reach-backs found in the same audit:
- nmE80DirectOps.pm [still to do]: C:/dat/Rhapsody/E80Configs and .../E80Screens hardcoded
  (-> $data_dir); also wants immediate-write last-used-folder state (a .json, not the ini).
- nmFrame.pm Commit/Revert "navMate.db to git" [DONE 2026-06-10]: dev-only; menu items now
  omitted when $Cava::Packager::PACKAGED (nmResources $database_menu).  The git ops keep their
  /dat/Rhapsody path -- unreachable in the packaged build.
- navServer.pm openMapBrowser [DONE 2026-06-10]: now the MAP_BROWSER pref -- value precedes the
  URL (e.g. 'firefox --new-window'); empty -> the system default browser.
- navMatchC.pm: _Inline under $app_dir -- the Inline::C-when-packaged question (still open).

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

### Seam pass -- 2026-06-10  (item c + prefs redesign + map browser + commit/revert gate)
- _res resource re-home: apps/navMate/_site -> _res/site, sym_catalog -> _res/sym_catalog
  (git mv, 54 renames).  n_utils.pm calls setStandardCavaResourceDir("$app_dir/_res") (dev =
  the in-repo _res; packaged = Cava bundle root).  navServer HTTP_DOCUMENT_ROOT = "$resource_dir/
  site"; nmResources.pm + winTreeColors.pm sym_catalog reads use $resource_dir.  Cava .cpkgproj
  local_config_values.resource_path set to .../_res so Cava bundles the whole _res tree.
- Prefs redesign (SUPERSEDES the a+b seed-file approach above): NO prefs file is written.
  init_prefs sets the changeable prefs into the hash as in-hash non-defaults (set-only-if-
  absent): DATABASE_PATH, MAP_BROWSER, DEPTH_DISPLAY, FAHRENHEIT.  HTTP_PORT's default lives in
  navServer->new() (setPref-if-absent there) so its config sits with the other HTTP_ params;
  getPref($PREF_HTTP_PORT) is the canonical read everywhere.  A hand-made navMate.prefs
  overrides any of them.  Rationale: a written file goes stale as code changes; defaults live
  in code, discoverable at their natural site (DB in navPrefs, port in navServer).
- MAP_BROWSER pref replaces the hardcoded firefox; _serverPort() helper removed (getPref is the
  read surface).
- Commit/Revert menu gated off when packaged (nmResources $database_menu).
- Icon: navMate.ico (multi-res, derived from _res/site/anchor.png) lives at _res/site/navMate.ico.
  The Windows exe icon is executable.icon_bundle, which Cava INTERNALIZES (buddy/cm store just a
  filename pointing into Cava's iconresource dir) -- so it must be set via the Cava GUI icon
  field (one click) pointing at that .ico; SQL alone cannot wire it.
- sym_catalog thumbnail cache [DONE 2026-06-10]: the 5 generated caches (20x20, 15x15,
  15x15_grey, leaflet_native, leaflet_mask) now write to $temp_dir/sym_cache -- writable in dev
  AND packaged -- instead of under $resource_dir (read-only when packaged).  Source symNN.png
  reads stay at $resource_dir/sym_catalog; each cache writer already mkdirs its target dir.
- KNOWN GAP: _Inline (navMatchC) still under $app_dir -- the Inline::C-when-packaged item, open.

## Installer (Inno Setup)

- installer_capable + doinstaller = 1 in cava20/msw/installer.config (the Storable hash, NOT the
  tracked .cpkgproj); a build then emits the Inno installer alongside the SFX.
- Cava 2.0 generates innosetup.iss for an older Inno; the installed Inno Setup 5.5.9 rejects three
  things in the raw file (ISCC stops at the first -- MinVersion):
    MinVersion=,<nt>           legacy 9x,NT comma form, invalid since 5.5.x dropped 9x support
    OutputManifestFile=<path>  a path is no longer accepted (bare filename only)
    [Languages] Basque/Slovak  those .isl files no longer ship
- Fix: apps/navMate/_installer/PreInstallApp.pm (set as installer.config pre_installer_script)
  rewrites innosetup.iss before the ISCC compile -- comments MinVersion, re-emits a bare
  OutputManifestFile in [Setup], drops the whole [Languages] section, adds CloseApplications=force.
  Modelled on buddy/cm's PreInstallApp; navMate's omits buddy's PATH-registry code.
- Artifacts: SFX = navmate-mswin-x86-<ver>.exe (run-in-place); installer = app-installer-<...>.exe
  ('app-installer' is Cava's placeholder base name -- rename later via installer.config name field).

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

## Inline::C / navMatch packaging

The Inline-C matcher loads and runs in the packaged build.  navMatch.pm, navMatchC.pm, winFind,
and Inline.pm all bundle normally -- Cava packs every module into the compressed package.lib, so
bundling is confirmed in build.log's "Building file" list, not by looking for loose files under
release/.

The compiled kernel cache -- config-MSWin32-x86-multi-thread-5.012004 plus
lib/auto/navMatchC_8dee/navMatchC_8dee.dll -- lives under the resource tree at _res/_Inline
(git-mv'd there from _Inline), so resource_path=_res bundles it into {app}/res/_Inline.

navMatchC.pm derives INLINE_DIR from $resource_dir/_Inline.  In dev that is the in-repo
_res/_Inline (writable, where Inline built it).  When $Cava::Packager::PACKAGED, navMatchC
xcopy's the bundled cache out to Win32::GetFullPathName("$temp_dir/_Inline") -- a writable,
drive-lettered temp dir -- and points Inline there.  Both fixes are required: Inline 0.5 rejects
a DIRECTORY that is read-only (Program Files) OR drive-less (the packaged $resource_dir is a
'/PROGRA~2/...' path); the copy-to-temp solves both.  INLINE_DIR is a hardcoded path, not an
@INC entry, so PERLLIB has no bearing on it.

The committed .dll loads as-is, no recompile: PE machine 0x014c (i386 / 32-bit x86), Inline key
MSWin32-x86-multi-thread-5.012004 -- identical to Cava's bundled perl (MSWin32-x86, 5.12.4).
Inline validates that key on load, so a mismatch is refused (rebuild) rather than mis-loaded.

Proven 2026-06-10: with the dev tree renamed aside and PERLLIB unset, the installed exe came up
self-contained and a Find returned real candidates -- the kernel loaded and ran from the bundled
cache.  See the memory [[inline-c-packaging-diagnosis]].
