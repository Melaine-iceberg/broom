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
 * - `broom/scan_priority` for lowering the process priority during a scan.
 * - `broom/file_metadata` for POSIX mode/timestamp restoration and volume IDs.
 */
void broom_register_native_channels(FlView* view, GtkWindow* window);

#endif  // RUNNER_NATIVE_CHANNELS_H_
