#pragma once
// WebKitGTK's GTK4 API series. The umbrella header pulls in GTK4, GLib, and
// JavaScriptCore (jsc_value_* — used to decode script-message bodies).
#include <webkit/webkit.h>
// g_unix_signal_add — SIGINT/SIGTERM sources dispatched on the GLib main loop,
// used by the shell to tear down the site container on Ctrl+C/kill.
#include <glib-unix.h>
