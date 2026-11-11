require "socket"

# The worker's end of mode offscreen: serves the harness's commands to a
# `Surface`, the app's window drawn without a compositor.
#
# The worker is a separate executable (`Subject#worker`) that takes the
# app's arguments, loads `.keymap` and polls `#fd` in its event loop,
# calling `#readable` when it can be read:
#
# ```
# require "livetest/worker"
#
# worker = Livetest::Worker.new(MySurface.new(window))
# loop.watch(worker.fd) { worker.readable }
# ```
#
# Raises `Error` when the harness did not start the process.
class Livetest::Worker
  # Raised when the worker runs outside the harness.
  class Error < Exception
  end

  # The window the harness drives. Coordinates are logical pixels relative
  # to the client area; key and button codes are evdev codes. Methods
  # raise to fail the command with the exception's message.
  module Surface
    # Returns the client area as *width*, *height* and RGBA bytes, top row
    # first.
    abstract def shot : {Int32, Int32, Bytes}
    abstract def key(code : UInt32, down : Bool) : Nil
    abstract def move(x : Float64, y : Float64) : Nil
    abstract def button(code : UInt32, down : Bool) : Nil
    # Scrolls *dy* wheel clicks down and *dx* right.
    abstract def scroll(dy : Int32, dx : Int32) : Nil
    # Configures the window to *width* x *height* logical pixels.
    abstract def resize(width : Int32, height : Int32) : Nil
    # Asks the window to close, as its close button does.
    abstract def close : Nil
    abstract def title : String
    # Calls *block* with the clipboard's text, empty when it holds none;
    # now or later, from the event loop.
    abstract def clipboard(&block : String ->) : Nil
    # Puts *text* on the clipboard as another program would.
    abstract def copy(text : String) : Nil
  end

  getter fd : Int32

  @socket : UNIXSocket
  @buffer = IO::Memory.new

  # Returns the keymap, in xkb text format, the harness's key codes refer
  # to.
  def self.keymap : String
    File.read(env("LIVETEST_KEYMAP"))
  end

  protected def self.env(name : String) : String
    ENV[name]? || raise Error.new("#{name} is not set; the harness starts the worker")
  end

  # Connects to the harness and drives *surface*.
  def initialize(@surface : Surface)
    @socket = UNIXSocket.new(Worker.env("LIVETEST_CONTROL"))
    @fd = @socket.fd
    # plain blocking reads and writes from the event loop's callback
    flags = LibC.fcntl(@fd, LibC::F_GETFL, 0)
    LibC.fcntl(@fd, LibC::F_SETFL, flags & ~LibC::O_NONBLOCK)
  end

  # Reads what arrived and runs the complete commands.
  #
  # Exits the process when the harness hung up.
  def readable : Nil
    chunk = Bytes.new(4096)
    n = LibC.read(@fd, chunk, chunk.size)
    exit 0 if n <= 0
    @buffer.write(chunk[0, n])
    lines = @buffer.to_s.split('\n')
    rest = lines.pop
    @buffer = IO::Memory.new
    @buffer << rest
    lines.each { |line| run(line) }
  end

  # :nodoc:
  # One command per line, answered with `ok [words]` or `error message`:
  #
  # | Command | Answer |
  # |---|---|
  # | `key CODE 1\|0` | presses or releases evdev key CODE |
  # | `move X Y` | moves the pointer (logical pixels) |
  # | `button CODE 1\|0` | presses or releases evdev button CODE |
  # | `scroll DY DX` | wheel clicks |
  # | `resize W H` | the window is configured to W x H |
  # | `close` | the user asks to close the window |
  # | `title` | `ok HEX` the title |
  # | `clipboard` | `ok HEX` the clipboard's text |
  # | `copy HEX` | another program offers the text on the clipboard |
  # | `shot` | `ok W H`, then W*H*4 bytes RGBA, top row first |
  private def run(line : String) : Nil
    w = line.split(' ')
    case w[0]?
    when "key"       then @surface.key(w[1].to_u32, w[2] == "1"); reply
    when "move"      then @surface.move(w[1].to_f, w[2].to_f); reply
    when "button"    then @surface.button(w[1].to_u32, w[2] == "1"); reply
    when "scroll"    then @surface.scroll(w[1].to_i, w[2].to_i); reply
    when "resize"    then @surface.resize(w[1].to_i, w[2].to_i); reply
    when "close"     then @surface.close; reply
    when "title"     then reply(@surface.title.to_slice.hexstring)
    when "copy"      then @surface.copy(String.new(w[1]?.try(&.hexbytes) || Bytes.empty)); reply
    when "clipboard" then @surface.clipboard { |text| reply(text.to_slice.hexstring) }
    when "shot"
      width, height, pixels = @surface.shot
      reply("#{width} #{height}")
      send(pixels)
    else
      error("unknown command #{line}")
    end
  rescue ex
    # any failure, of the line or of the surface, fails only this command
    error(ex.message || ex.class.name)
  end

  private def reply(words : String? = nil) : Nil
    send(words ? "ok #{words}\n" : "ok\n")
  end

  private def error(message : String) : Nil
    send("error #{message.gsub('\n', ' ')}\n")
  end

  private def send(data : String) : Nil
    send(data.to_slice)
  end

  private def send(data : Bytes) : Nil
    until data.empty?
      n = LibC.write(@fd, data, data.size)
      exit 0 if n <= 0
      data += n
    end
  end
end
