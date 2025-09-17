# Forensics Log

A non-hierarchial, stream of conciousness log of efforts to "figure out"
Raynet RNS and the RaynetHS ethernet protocols with regards to getting
a workable RWT (Routes, Waypoints, and Tracks) managament workflow.


### Baseline

First of all, note that Raytech RNS might/will "hang" as a background process
if there is a network connection and it cant find Raynet (UDP) packets from
the E80.

So, to run it "cold" (in "Planning Mode"), you may (probably) need to turn
off Wifi and make sure the ethernet is not plugged in.

Presumably one could even connect to the E80 over Wifi.

My general plan is to

- remove the Caribbean CF chart card from the E80 for safety
- delete all of the RWT's from Raytech RNS
- delete everything except for the Popa Waypoints, Route, from the E80.
- generate a single track on the E80 using teensyBoat simulator, probably NMEA0183.

Then see if I can get an Archive.FSH from the E80 to the laptop with RNS
over ethernet.


### Startup (raylauncher.exe vs raytechnavigator.exe)

Apparently RNS can run in "Planning" or "Onboard" mode, and I seem to
have it stuck in "Onboard" mode.  Planning mode may very well skip the
network check that prevents RNS from coming up from the background unless
it finds the E80 (RaynetHS).

Aparently also there is a way to hook Seatalk directly to the PC and RNS.

I can find no menu options in RNS that allow me to toggle Planning/Onboard mode.

That is because there is a separate startup program and I have created
a shortcut directly to the main executable.  The startup executable just
shows the "Planning/Onboard" dialog box (and would have asked for the
license key if one had not been installed previously) and then chains
to the main executable.

**raylauncher.exe**

Once raylauncher.exe is executed in Planning or Onboard mode, presumably,
the main raytechnavigator.exe comes up in the given mode.  Therefore there
is an ini file or registry entry someplace that is telling it what mode to
come up in.

### Planning Mode

When I started in Planning mode, RNS shows "Raytech Simulate Mode",
gives me dialogs that say "Unable to read chart. Please make sure you
are using the E86026 Navionics Multicard Reader", with the boat positioned
in Miami, with a few AIS contacts around it.

Initially, as I had not "cleaned" RNS, it still contained my Popa Route
and Waypoints folder, as well as a testFolder33 I had created.

One of my dilemmas is that in Onboard mode, with the E80 on the net,
I appears as if RNS is considered the "master", and the E80 is "normalized"
with the Routes and Waypoints from RNS.  This may be an "additive merge"
so that info on the E80 is not lost.  So, once again, the baseline test
scenario will be invoked.


### Empty RNS - Planning mode

Export -> File - to C/E Series File Format - Export All Routes and Waypoints

- does not work with cleaned RNS, giving two errors:
  - no Waypoints selected for transfer
  - no Routes or Waypoints Exported

So I created a single WP at cursor in middle of Bocas Island,
opened it's properities and renamed it "IslaColon" and did
another export, to /Archive/Archive.FSH.  I could have exported
it anywhere but am using /Archive for convenience and ease of RNS use.

I am using fshConvert to look at the output.  There is now
an Archive.FSH with that one waypoint.


### E80 cleanup

I removed all Waypoints and Routes except for the
Popa Waypoint Group (with Popa Waypoints) and the
Popa Route (implicitly contains popa waypoints).

I decided to use teensyBoat to build an identifiable
track in the E80 by driving 20knots from Popa01 to
Popa10 (at 90 knots!) using the NMEA0183 simulator.

So now I have some "precious" information on the E80
and nothing in RNS and will see what happens when I
connect them both via ethernet.

For "safety" ... I decided to back the E80 up to a
blank, brand new CF card.  Note that on the E80 you
have to do three separate exports for Waypoints,
Routes, and Tracks, answer "All" to each, and then
Setup-Remove CF card.

That file copied to **/Archive/BASELINE.FSH** for
future use.

### Hookup E80

Using the network setup described in readme.md, but
a standard shielded ethernet cable rather than the official
raymarine cable to the router, I verified that the E80
is on the net with my /NET/raynet.pm program, and,
indeed I am getting lots of UDP packets.


### Restart RNS in "Onboard" Mode

Which then forced me to through an instrument setup cycle
where I selected the Raymarine HS internet, but told it
I was not connected to the boat.  It made me select a
network adapater, so I picked the PCI ethternet one, then
it made me reboot.

Starting RNS directly, without the "raylauncher.exe" now.

I can see that RNS has gotten the Route and WP's from the E80,
but it is in an endless loop with a dialog box saying Route Complete
in Arrival Circle.  I think I need to turn off routing on the
teensyBoat simulator.

Hmmmm ... routing and autopilot was already off, the boat's not
moving.  So I "jumped" to first to waypoint(1) (Popa1) and then
to waypoint(0) (Popa0), and the arrival circle dialog stopped.
Now I can look a lttle closer at what data exists.


Firstly, I can see in RNS that

- It has the Isla Colon Waypoint on the screen.
- It has the Popa Route on the screen.
- There is a flashing square on Popa10 indicating that
  someone still thinks we are navigating to that waypoint
  (probably because I never "cancelled" the NMEA0183
  "target waypoint" message)
- It shows a dashed line from the boat (at Popa0) to
  Popa10, which is presumably the heading to the target
  waypoint.
- It has a solid black line from Miami to Popa10 to
  Popa1 to Popa0 which is presumably an RNS-Track
  from the last place the simulator thought we were
  Miami, to the current location.

Looking at "Manage Waypoints"

- There is a Popa folder that presumably has all the popa waypoints.
- There is a My Waypoints folder that has
  - the Isla Colon waypoint created in Planning mode.
  - a waypoint called "Popa10" which I *think* is a temporary
    waypoint that I generated with an NMEA0183 "target waypoint"
    message.

And in "Manage Routes"

- There is a Popa folder that presumably has all the popa waypoints
- There is an "InstantRoute" folder that, presumably just has the
  Popa10 generated waypoint.

For grins and giggles, I change the MyWaypoints/Popa10 waypoint to
"Gen10" to differentiate it as a generated waypoint.

THERE IS NOW AN InstantRoute folder in ManageWaypoints that has
the Popa10 (generated?) waypoint. I rename THAT to "Gen10".
A green line pops up from latlon(0,0) to Popa10 sigh, so
apparently the instant route goes from latlon(0,0) WTF these
semantics mean.

Popa10 is no longer in the Popa waypoints folder.


On the E80 I go looking for the IslaColon waypoint, turn on
"Show" for the My Waypoints folder, and notice that I actually
put the waypoint in th emiddle of Isla Bastiamentos.

Something mysterious and elusive is happening.

I *think* I *was* able to create a waypoint on the E80 with NMEA0183.

This "Instant Route" is confusing.  The green line is apparently
now part of the Popa Route, though there is no waypoint at latlon(0,0).

Now there is no longer a Popa Folder in ManageWaypoints! WTF.
All of them (except for Popa10) have been moved to MyWaypoints in RNS.

On the E80 they appear to still exist in a Popa Waypoint "Group".
Confusing terminology changes; waypoints changing folders on their own,
and no clear idea of how they are normalized to the E80.
What a fucking mess.

And there's still a black line (a Track?) in RNS from Miami to Bocas
as I struggle to find the menu commands for Tracks in RNS.

Hmmmm ... Under "File-Tracks" there's

- Enable Logging
- Load Track
- Clear Track
- Save to Database

Yet no apparent way to ManageTracks ...


Sigh.


### Try to get TrackP1 from E80 to RNS ...


Once again, it feels like RNS has it's own totally separate
notion of tracks which has nothing to do with the ones on the
E80.   There is no obvious way to upload or download them
from the E80.

On the other hand it is opaquely mirroring everything that
was already on the E80, so it is not clear what it means
to "Load" data from "the network".

And also, If I delete anything in RNS, it is likely to delete
it from the E80.

I think a "Track" in RNS is a subset of the "Logging"
capabilities which apparently uses a "database" which
is likely not the ARCHIVE.FSH.


Import Routes and Waypoints - From Network - From SeatalkHS Network

Note that there is also an "HSB" network, whatever that is.

"Import Successful" ... Now the Popa folder is back.



I'm gonna shut down and restart RNS to see if the line from Miami
goes away.  YUP, it did.  So that artifact implies that RNS is storing
the boat's location persistently and then considers it to have moved
upon a restart.  The black line is what, a track?


### DELETE EVERYTHING FROM E80 and RNS and run a simulated route.

I have to cleanu p this mess to get some kind of idea of the semantics
involved.  Especially intriguing is the possibility that I can create
tracks and routes on the E80 with NMEA0183, which is clearly imnplied
in the RNS documentation.

Deleting all Tracks, Routes, Waypoint Groups, and the final waypoints
from MyWaypoints folder on E80 and everything also disappeared in RNS

EXCEPT FOR Popa10 which is still there flashing in RNS and with
a WHITE_BOX_N waypoint symbol on th eE80 ...

Presumably somehow I am still "Following" or have an active target
waypoint.  It still shows in MyWaypoints folder in RNS, but not
on the E80. When I clicked Route-ClearRoute in RNS it temporarily
disappeared and then re-appeared.  When I pressed "GOTO.." and
then "STOP GOTO" on the E80 it stopped flashing in RNS, but then
started flashing again. In RNS under the menu Route-FollowRoute
item has a checkbox I cannot seem to turn off.

The help files are useless.

Created WP "Cristobal" in the middle of that island.
Right Clicking on and selecting "Goto Cursor" moved
the flashing red box in RNS and the white box on the E80

Right clicking in middle of Basti and GotoCursor
created a new waypoint "Wp" on Basti. It is
now in MyWaypoints WP folder and the InstantRoute
route.

Apparently RNS requires an active Route and at least one
waypoint.  And you can never turn off "Follow Route".


So, now I have a route testRoute consisting of only
the Cristobal waypoint.  Note that even after it was
gone from RNS I had to manually delete the instRoute
route from the E80.

It reappeared in RNS.  What bullshit.

After ManageRoutes-testRoute right click activate,
the stupid instantRoute went away.

Now I have one route testRoute consisting of one
waypoint cristobal on both RNS and the E80.


So what happens if I now run the sim.

Ap=1, R=1, and start monitoring m_0183=1 and
I see some interesting stuff.

I am sending out $APRMB with the Popa start and
target waypoints, but am getting $ECRMB with the
Cristobal waypoint ... the RNS route is overriding
the NMEA0183 route.

- The E80 shows a target waypoint of Cristobal.

S=10 to start the boat moving.
The boat is moving, but contrary to before (?),
NMEA0183 does not appear to be driving it.

Lets try I_ST=1, I_0183=0

- the RNS route leg disappeared.
- The Route-Follow Route checkbox disappeared

I don't know what changed.  I am having a hard time remembering.
The E80 is not acting the same with RNS running as it did standalone.

Now what happens if I switch back to I_0183=1 I_ST=0

Nothing.  The boat is moving, but the E80 is "NOT FOLLOWING".

The E80 shows a distance to the waypoint of 4.70 NM with
a time decreasing from 1hr24minutes which is also shown in
the Waypoint TTG box.  RNS is popping back and forth from
Mark Range 0.37nm to 4.63nm,


Started my raynet.pm with $SHOW_UI=1.   I'm getting
lots of "bells" ... I can see data changing in the ascii
portion but they are not channgin (or shown in red) in the
message section, which I think is a bug (or poor implementation)
in raynet.pm.  I never learned
to decode UDP range to target and don't see a waypoint
name in there, but of course they're proabably weirdly
encoded.

To prove the bells were coming from my raynet.pm program
I stopped it. No bells. Restarted it. No more bells.

No clue.


Grrrrrrrrr ....

Fixed a bug in ray_E80.pm that was not showing changes
in red.  The effing lat and lon fields are not changing
even though the boat is moving.

For sanity I now have to stop RNS and see if the E80
starts responding like it used to.

Nope.  Now I'm gonna reboot the E80.

Now, with I_0183=1, the E80 is showing the Popa02 waypoint
like it did before. A new super short Type(300) version(4)
UDP message is shosing the LAT/LON changing.

Also, FWIW, there is a WHITE-N target on the E80 but
no waypoint in any lists, nor a route of any kind.

Restarting RNS ..

- 1 stuck in background mode, no changes in raynet.pm
- kill in task manager and start again
- comes up and shows popa031 waypoint.
- E80 still shows WP
- there is now an instantRoute.
- On the E80 the previous waypoint Popa03 and a WHITE-N symbol shows
  In RNS the previous WP (Popa03) and target (Popa04) shows.
- RNS has it's own calculation and dialog box for entered arrival circle.
- It also shows a WP ARRIVAL dialog box while I am making the E80 beep from NEMA0183

Weird.

The RNS shows "instantRoute as having one waypoint, the next one.
The E80 shows "instantRoute" as having one waypoint, the previous one.
There is now a Popa04 waypoint in RNS/MyWaypoints and RNS/InstantRoute folders.

I believe there is an NMEA0183 sentence sequence to send a complete route.

ON advancing WP from Popa04 to Popa05 in teensyBoat

- RNS does NOT show Popa04 anymore
- E80 did NOT start showing Popa04 waypoint.
- Flashing Waypoint Popa05 in rns
- WHITE-N moved to Popa05 on e80
- The pattern repeated on subsquen arrival through Popa05

Presumption: RNS needed at least one waypoint for the route
so it accepted Popa03.  InstantRoutes are wacky and interpreted
differently in RNS and E80.  Magic assumptions, weird behavior.














