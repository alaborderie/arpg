class_name SyncConfig
extends RefCounted
## Client-side toggle and endpoint for cloud save sync (M5). See docs/0013.
##
## `enabled = false` is the escape hatch offline-first requires: every gdUnit
## scene test that boots `main.tscn` sets it before instantiating the scene
## (the same idiom those tests already use for pinning `rng_seed` to opt out
## of disk save-loading) so no test ever depends on network timing. The real
## boot path (`godot --headless --path game --quit-after 120`, and normal
## play) leaves it `true`: [SyncService] must stay silent and non-blocking
## even then, with no server running - that IS the offline-first acceptance
## bar, not a reason to disable sync in that path.

const DEFAULT_BASE_URL: String = "http://localhost:8080"
## Short on purpose: an unreachable dev server should fail fast rather than
## hang the boot sequence's background sync coroutine for multiple seconds.
const REQUEST_TIMEOUT_SEC: float = 3.0

static var enabled: bool = true
static var base_url: String = DEFAULT_BASE_URL
