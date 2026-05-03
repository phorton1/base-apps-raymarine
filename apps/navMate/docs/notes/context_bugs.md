# navMate — Context Menu Bugs

Real code issues, data corruption, and unexpected behaviors found during testing.
Unimplemented features and implementation gaps belong in the implementation plan, not here.


## Open

### ops-not-atomic

A context operation that fails mid-batch can leave the DB and E80 in inconsistent
state. Example: a route's member WPs are created on E80 but the route record is not,
leaving orphan waypoints on E80 with no route referencing them. E80 has no rollback.

This is a known architectural limitation deferred past alpha. Promoted here because
a mid-operation failure (network drop, E80 error) does produce real, persistent
corrupt state with no recovery path.


## Closed

(none yet)
