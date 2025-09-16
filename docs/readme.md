# readme for /base/bat/raymarineE80

Perl code specific to the boat's instrument systems, particularly the E80.
It consists of a number of Perl programs

- fshConvert.pm converts FSH files into GPX or KML files
- kmlToCSV.pm converts KML files into (Raytech) CSV files
- kmlToFSH.pm is an incomplete experimental attempt to write an FSH file
- raynet.pm is my current wip for messing with RaytechHS (ethernet)

There is an experimental program **kmlToFSH** that endeavoured to write an FSH
file, bypassing Raytech RNS, that would have still required a CF card, but it was
never completed.

This readme file discusses my basic Text based Route and Waypoint management
approach, and the network configuration to connect the E80 to the laptop
for running RNS and for my raynet experiments.

See raynet.md for my progress in deciphering the SeatalkHS (ethernet)
protocols used by RNS and the E80.


## FSH File Converstions (Text Approach)

Implements my current (only) Text based Route, Waypoint, and Track management
approach to store, develop, and archive information in Google Earth and get it
from, or send it to, the E80 in one form or another.

The initial requrement, since met, was to get all of the Tracks, Waypoints, and
Routes off of the old broken E80.  I was able to use it well enough (the screen
is bad) to get an ARCHIVE.FSH file onto a CF card, and onto the laptop.

### FSH Files to Google Earth

The program **fshConvert.pm** has the ability to read FSH files and convert them
into either KML or GPX files that can then be imported in to Google Earth.

It includes the following perl packages, whish should not be confused with
executable "programs".

- fshBlocks.pm
- fshConvert.pm
- fshFile.pm
- fshUtils.pm
- genGPX.pm
- genKML.pm

The ouitput KML format contains my conventions for Google Earth including folders,
tracks, markers, etc.

### KML Files to CSV Files

The program **kmlToCSV.pm** converts my known Google Earth conventions Waypoints
and Routes folders into a Raytech compatible CSV file, which can then be saved
as an FSH file and transferred to the E80 by CF Card (or possibly sent directly
to the E80 over ethernet).

The CSV files into RNS only contain Routes, Folders, and Waypoints.  They do not
contain Tracks.


### Raytech RNS Import/Export (Usage)

Raytech RNS depends on the existence of a **C:/Archive** folder:

- It MUST contain a file called RTWptRte.TXT or you cannot import from CSV files.
- It PROBABLY needs an ARCHIVE.FSH because that's the 'database' for Raytech RNS.

Note that Rayech RNS does NOT use or mirror E80 tracks, although it can facilitate
getting them from the E80 in an FSH file.



## Desktop Network Configuration

Using the new E80 #1 to the Archer C20–AC750 Router to th Laptop

Starting with the fact that the New E80 shows an IP address of 10.0.241.54,
I configured the Router with an IP address of 10.0.241.254 and the laptop
with a fixed ethernet address of 10.0.241.200.

Thus far it only works when I use the official shielded rayMarine ethernet cable.

**The Laptop can be connected Wirelessly to the router, but that means
you have to be off the net.**

The router is setup with DHCP but uses address reservation to make sure
that the new E80 at mac address 00:11:C7:00:F1:36 is reserved for
10.0.241.54, and the laptop is at 200.

With this, RNS should come alive and/or when connecting to the E80 simultaneously
with a Seatalk, NMEA0183, or NMEA2000 simulator, deciphering and learning about
the Raynet protocols.









