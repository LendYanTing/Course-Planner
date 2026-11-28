#ifndef RUNNER_WINDOW_STATE_H_
#define RUNNER_WINDOW_STATE_H_

#include <windows.h>

// Persists the desktop window's size/position between runs.
//
// Stored as logical pixels (physical / monitor scale) so a later run on a
// different DPI monitor applies its own scale exactly once in
// Win32Window::Create. The file lives under
// %LOCALAPPDATA%\CoursePlanner\window_state.txt; a missing or off-screen
// placement falls back to a sensible default.
namespace window_state {

struct Placement {
  int x = 120;
  int y = 80;
  int width = 1280;
  int height = 720;
  bool maximized = false;
  // False when no usable saved placement exists; the caller then treats
  // width/height as logical and lets Win32Window scale them for the monitor.
  bool valid = false;
};

// Reads the last placement. Never throws; bad/missing data yields defaults.
Placement Load();

// Saves the window's normal (restored) bounds and whether it is maximized.
void Save(HWND window);

// True when the placement loaded by Load() asked for a maximized window.
bool StartMaximized();

}  // namespace window_state

#endif  // RUNNER_WINDOW_STATE_H_
