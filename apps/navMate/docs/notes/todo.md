# navMate Todo

[name] identifiers cross-reference open_bugs.md, design_vision.md, or docs/
where those hold canonical context. Items without a canonical home carry their
own context here.

---

## Next

[d_TRACKS missing $progress support]
d_TRACK implementation is lacking progress support and needs it to properly bracket
operations like Cleanup-E80 which deletes both tracks and waypoints/groups/etc,
and then needs to be reworked into the aggregate scheme to properly implement
operations like cut-E80-paste-DB tracks.

[leaflet sym-icons] - work pending in leaflet to display the correct symbol
icon type (all three sources) for waypoints. Pending getting the darned icons
that match the e80 "sym_catalog" raw pictures we currently are using for the
app in sym-selection in editors etc.


[remove database track ts_start and ts_end times]
- make sure they're not used in phorton.com building process



## Soon



### [sort database collecton context menu command]
I would like the ability to sort the immediate children of at least a single selected
collection (branch or group). The simplest visision is a collection of terminal "objects"
that would be sorted by their name.  The sort is essentially lexical but for two objects
that have the same prefix but only end in digits different, the digits would be sub-sorted
numerically. My vision is not so clear when the children of the colllection also includes
other collections.  On the one hand, the same sort criteria could be used and so collections
would normally end up inter-mixed with terminal objects in the resultant ordering. On
the other hand, it might be nice to have something like the way windows explorer puts
collections at the top, and then terminal objects after them.   Possibly if, upon executing
the sort command, the system detected a collection in the children, it could then provide
a UI to allow the user to specify the sort criteria in that one case.

The other insteresting idea is to allow sorting of an explicit non-sparse range selection
of items within a single parent ... sorting them in place as a group.  I could see that
being handy, though the ui for the collection first would hardly seem to make sense in
that case.





## Ongoing

### [oldE80 archaeology]
Patrick-managed. Full checklist in `docs/notes/oldE80-Fixup.md`.

