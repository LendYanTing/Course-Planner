#include "window_state.h"

#include <algorithm>
#include <fstream>
#include <string>

namespace {

constexpr int kMinWidth = 900;
constexpr int kMinHeight = 600;
constexpr int kMaxSize = 12000;

bool g_start_maximized = false;

std::wstring StatePath() {
  wchar_t buffer[MAX_PATH] = {};
  DWORD length =
      ::GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, MAX_PATH);
  std::wstring dir = length > 0 ? std::wstring(buffer, length) : L".";
  dir += L"\\CoursePlanner";
  ::CreateDirectoryW(dir.c_str(), nullptr);
  dir += L"\\window_state.txt";
  return dir;
}

}  // namespace

namespace window_state {

Placement Load() {
  Placement placement;
  std::wifstream input(StatePath().c_str());
  if (!input.is_open()) {
    return placement;
  }
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
  int maximized = 0;
  if (!(input >> x >> y >> width >> height >> maximized)) {
    return placement;
  }

  width = std::clamp(width, kMinWidth, kMaxSize);
  height = std::clamp(height, kMinHeight, kMaxSize);

  RECT rect = {x, y, x + width, y + height};
  if (::MonitorFromRect(&rect, MONITOR_DEFAULTTONULL) == nullptr) {
    // The old monitor is gone (undocked laptop, changed layout): keep the
    // saved size but let Windows place the window on the primary monitor.
    return placement;
  }

  placement.x = x;
  placement.y = y;
  placement.width = width;
  placement.height = height;
  placement.maximized = maximized != 0;
  placement.valid = true;
  g_start_maximized = placement.maximized;
  return placement;
}

void Save(HWND window) {
  if (window == nullptr || !::IsWindow(window)) {
    return;
  }
  WINDOWPLACEMENT placement = {};
  placement.length = sizeof(placement);
  if (!::GetWindowPlacement(window, &placement)) {
    return;
  }
  // rcNormalPosition is the restored rect even when the window is maximized.
  // Stored in physical pixels: Win32Window::Create restores saved placements
  // verbatim instead of scaling them a second time.
  const RECT& rect = placement.rcNormalPosition;
  const int x = rect.left;
  const int y = rect.top;
  const int width =
      std::clamp(static_cast<int>(rect.right - rect.left), kMinWidth, kMaxSize);
  const int height =
      std::clamp(static_cast<int>(rect.bottom - rect.top), kMinHeight, kMaxSize);
  const bool maximized = placement.showCmd == SW_SHOWMAXIMIZED;

  std::wofstream output(StatePath().c_str(), std::ios::trunc);
  if (!output.is_open()) {
    return;
  }
  output << x << L' ' << y << L' ' << width << L' ' << height << L' '
         << (maximized ? 1 : 0);
}

bool StartMaximized() {
  return g_start_maximized;
}

}  // namespace window_state
