// C ABI of island-core. All strings are UTF-8 JSON; free returned strings with island_free.
#pragma once

typedef void (*island_snapshot_cb)(const char *json, void *ctx);

// config: {"supportDir","home","hookSource"?,"socket"?}. Returns NULL on success, else error JSON.
char *island_start(const char *config, island_snapshot_cb cb, void *ctx);
// Fire-and-forget: {"type":"viewed","agent","id"} | {"type":"pause","paused"}
void island_send(const char *command);
// Synchronous: {"op":"planInstall"|"applyInstall"|"planUninstall"|"applyUninstall"|"snapshot", ...}
// Open PR (slow: call off the main thread): {"op":"prReady","cwd","offered"} -> Ready|null,
// {"op":"prCreate","cwd","agent","base","recap"} -> {url,number,existing}, {"op":"prCancel","cwd"}.
char *island_call(const char *request);
void island_free(char *s);
