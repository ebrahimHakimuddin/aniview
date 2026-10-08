#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {
std::wstring Wide(const std::string& value) {
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.data(),
                                     static_cast<int>(value.size()), nullptr, 0);
  std::wstring result(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      result.data(), size);
  return result;
}

LSTATUS SetProtocolValue(const wchar_t* path, const wchar_t* name,
                        const std::wstring& value) {
  HKEY key;
  LSTATUS status = RegCreateKeyExW(HKEY_CURRENT_USER, path, 0, nullptr, 0,
                                  KEY_SET_VALUE, nullptr, &key, nullptr);
  if (status != ERROR_SUCCESS) return status;
  status = RegSetValueExW(key, name, 0, REG_SZ,
                        reinterpret_cast<const BYTE*>(value.c_str()),
                        static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
  RegCloseKey(key);
  return status;
}

LSTATUS RegisterSignInScheme() {
  wchar_t executable[32768] = {};
  if (!GetModuleFileNameW(nullptr, executable, 32768)) return GetLastError();
  LSTATUS status = SetProtocolValue(L"Software\\Classes\\aniview", nullptr,
                                   L"URL:AniView sign-in");
  if (status != ERROR_SUCCESS) return status;
  status = SetProtocolValue(L"Software\\Classes\\aniview", L"URL Protocol", L"");
  if (status != ERROR_SUCCESS) return status;
  return SetProtocolValue(L"Software\\Classes\\aniview\\shell\\open\\command",
                          nullptr, L"\"" + std::wstring(executable) + L"\" \"%1\"");
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  app_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "aniview/app",
      &flutter::StandardMethodCodec::GetInstance());
  app_channel_->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() == "open") {
      const auto* url = call.arguments()
          ? std::get_if<std::string>(call.arguments()) : nullptr;
      if (!url) { result->Error("open", "Missing URL"); return; }
      // Pass the complete URL to the default browser without cmd.exe parsing &.
      const auto opened = reinterpret_cast<INT_PTR>(ShellExecuteW(
          nullptr, L"open", Wide(*url).c_str(), nullptr, nullptr, SW_SHOWNORMAL));
      if (opened <= 32) result->Error("open", "Could not open the browser");
      else result->Success();
    } else if (call.method_name() == "registerSignInScheme") {
      if (RegisterSignInScheme() == ERROR_SUCCESS) result->Success();
      else result->Error("register", "Could not register the sign-in callback");
    } else {
      result->NotImplemented();
    }
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  app_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
