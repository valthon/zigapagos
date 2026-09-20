### Fixed

- Dev browsers recover missed updates after a dropped live-reload connection or a server restart at the same address. SSE cursors distinguish a stale page from a current one; catch-up uses a full refresh so multiple missed changes are not reduced to the latest island delta. Chrome regression coverage exercises failure/repair, successive HTML/CSS edits, reconnect stability, restart and server teardown. Root configuration changes still require restarting dev; failed builds do not promise a preserved output snapshot.
