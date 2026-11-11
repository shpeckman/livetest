require "./app"
require "./case"
require "./image"
require "./keymap"

# :nodoc:
# Where the app runs and how the harness reaches it: placing the window,
# input, screenshots, the clipboard. Coordinates are logical pixels relative
# to the window's client area; key and button codes are evdev codes.
abstract class Livetest::Backend
  class Error < Exception
  end

  BTN_LEFT   = 0x110_u16
  BTN_RIGHT  = 0x111_u16
  BTN_MIDDLE = 0x112_u16

  getter keymap : Keymap

  def initialize(@keymap : Keymap)
  end

  # Returns the program and arguments that start the app with *args*.
  def command(binary : String, args : Array(String)) : {String, Array(String)}
    {binary, args}
  end

  # Returns the environment to add for the app of *app_id* in *dir*.
  def env(app_id : String, dir : String) : Hash(String, String?)
    tool_env
  end

  # Returns the environment for the clipboard and screenshot tools.
  def tool_env : Hash(String, String?)
    {} of String => String?
  end

  # True when the backend takes over the user's keyboard and pointer.
  def grabs_input? : Bool
    false
  end

  # Waits until *app*'s window is up, then places and focuses it.
  abstract def open(app : App, test : Case, timeout : Time::Span) : Nil
  # Gives the window the keyboard focus again if it lost it.
  abstract def focus : Nil
  abstract def shot : Image
  # Resizes the client area to *width* x *height* logical pixels.
  abstract def resize(width : Int32, height : Int32) : Nil
  # Asks the window to close.
  abstract def close_window : Nil
  abstract def title : String?
  abstract def key(code : UInt16, down : Bool) : Nil
  abstract def move(x : Int32, y : Int32) : Nil
  abstract def button(code : UInt16, down : Bool) : Nil
  # Scrolls *dy* wheel clicks down and *dx* right.
  abstract def scroll(dy : Int32, dx : Int32) : Nil

  # Returns the clipboard's text, empty when it holds none.
  def clipboard : String
    buffer = IO::Memory.new
    status = Process.run("wl-paste", ["-n"], env: tool_env, output: buffer, error: Process::Redirect::Close)
    status.success? ? buffer.to_s : ""
  rescue File::NotFoundError | IO::Error
    raise Error.new("wl-paste is missing")
  end

  # Puts *text* on the clipboard.
  def copy(text : String) : Nil
    status = Process.run("wl-copy", ["--", text], env: tool_env, output: Process::Redirect::Close,
      error: Process::Redirect::Close)
    raise Error.new("wl-copy failed") unless status.success?
  rescue File::NotFoundError | IO::Error
    raise Error.new("wl-copy is missing")
  end

  # Ends the case of *app*: the window goes away.
  def finish(app : App) : Nil
  end

  # Releases everything the backend holds.
  def close : Nil
  end
end

# :nodoc:
# The backends: `KDE`, `Sway` and `Offscreen`.
module Livetest::Backends
end
