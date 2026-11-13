// Force-included into flutter_inappwebview_linux when it's built against WPE WebKit older than 2.50
// (see CMakeLists.txt): a page's theme colour can't be read there, so there is none.
#define webkit_web_view_get_theme_color(view, color) FALSE
