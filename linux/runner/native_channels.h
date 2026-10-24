#ifndef RUNNER_NATIVE_CHANNELS_H_
#define RUNNER_NATIVE_CHANNELS_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

/**
 * broom_register_native_channels:
 * @view: the view whose engine hosts the channels.
 * @window: transient parent for native file dialogs; must outlive @view.
 *
 * Registers the Broom platform channels:
 * - `broom/shell` for disk space, file dialogs and revealing paths.
 * - `broom/scan_priority` for lowering CPU and I/O priority during a scan.
 * - `broom/file_metadata` for POSIX ownership/mode/timestamp/xattr restoration.
 * - `broom/file_lock` for advisory write-lock probing.
 * - `broom/directory_enum` for readdir + statx directory listings.
 * - `broom/system` for the build-time application version.
 * - `broom/window` and `broom/window_state` for the Flutter title bar.
 */
void broom_register_native_channels(FlView* view, GtkWindow* window);

/**
 * broom_install_window_handles:
 * @window: the undecorated window.
 * @overlay: a #GtkOverlay containing the Flutter view.
 *
 * Adds transparent edge widgets that start a resize drag. Undecorated windows
 * have no window-manager resize borders, so the client has to provide them.
 */
void broom_install_window_handles(GtkWindow* window, GtkWidget* overlay);

#endif  // RUNNER_NATIVE_CHANNELS_H_
