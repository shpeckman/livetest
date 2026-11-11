require "socket"
require "../backend"

# :nodoc:
# The app's window code run by its worker (`Subject#worker`) without a
# compositor or input devices. The worker connects to a socket per case
# and answers line commands (see `Livetest::Worker`).
class Livetest::Backends::Offscreen < Livetest::Backend
  @worker : String
  @dir : String
  @keymap_path : String
  @server : UNIXServer? = nil
  @control_path = ""
  @conn : UNIXSocket? = nil
  @count = 0
  # The worker closed the connection.
  @gone = false

  # Uses the worker *worker*.
  def initialize(@worker : String)
    super(Keymap.new(nil, nil, nil, nil, 0))
    raise Error.new("no worker #{@worker} (make builds it)") unless File::Info.executable?(@worker)
    base = ENV["XDG_RUNTIME_DIR"]?.presence || Dir.tempdir
    @dir = File.join(base, "livetest-#{Process.pid}")
    Dir.mkdir_p(@dir, 0o700)
    @keymap_path = File.join(@dir, "keymap.xkb")
    File.write(@keymap_path, keymap.text)
  end

  def command(binary : String, args : Array(String)) : {String, Array(String)}
    {@worker, args}
  end

  def env(app_id : String, dir : String) : Hash(String, String?)
    @count += 1
    @control_path = File.join(@dir, "control-#{@count}")
    File.delete?(@control_path)
    @server = UNIXServer.new(@control_path)
    {"LIVETEST_CONTROL" => @control_path, "LIVETEST_KEYMAP" => @keymap_path} of String => String?
  end

  def open(app : App, test : Case, timeout : Time::Span) : Nil
    server = @server || raise Error.new("no control socket")
    server.read_timeout = 100.milliseconds
    deadline = Time.instant + timeout
    until @conn
      begin
        @conn = server.accept
      rescue IO::TimeoutError
        raise Error.new("the app exited before its window opened") if app.exited?
        raise Error.new("no window after #{timeout.total_seconds}s") if Time.instant >= deadline
      end
    end
  end

  def focus : Nil
  end

  def shot : Image
    words = request("shot")
    w, h = words[0].to_i, words[1].to_i
    pixels = Bytes.new(w * h * 4)
    conn.read_fully(pixels)
    Image.new(w, h, pixels)
  rescue ex : IO::Error
    raise Error.new("the worker went away: #{ex.message}")
  end

  def resize(width : Int32, height : Int32) : Nil
    request("resize #{width} #{height}")
  end

  def close_window : Nil
    request("close")
  end

  def title : String?
    String.new(request("title")[0]?.try(&.hexbytes) || Bytes.empty)
  end

  def key(code : UInt16, down : Bool) : Nil
    input("key #{code} #{down ? 1 : 0}")
  end

  def move(x : Int32, y : Int32) : Nil
    input("move #{x} #{y}")
  end

  def button(code : UInt16, down : Bool) : Nil
    input("button #{code} #{down ? 1 : 0}")
  end

  def scroll(dy : Int32, dx : Int32) : Nil
    input("scroll #{dy} #{dx}")
  end

  def clipboard : String
    String.new(request("clipboard")[0]?.try(&.hexbytes) || Bytes.empty)
  end

  def copy(text : String) : Nil
    request("copy #{text.to_slice.hexstring}")
  end

  def finish(app : App) : Nil
    @conn.try(&.close)
    @conn = nil
    @gone = false
    @server.try(&.close)
    @server = nil
    File.delete?(@control_path)
  end

  def close : Nil
    FileUtils.rm_rf(@dir)
  end

  private def conn : UNIXSocket
    @conn || raise Error.new("the worker is not connected")
  end

  # Sends the input event *line*; input to a worker that already exited is
  # lost, like input to a closed window.
  private def input(line : String) : Nil
    return if @gone
    request(line)
  rescue ex : Error
    raise ex unless @gone
  end

  # Sends *line* and returns the words after `ok`.
  private def request(line : String) : Array(String)
    io = conn
    io << line << '\n'
    io.flush
    unless reply = io.gets
      @gone = true
      raise Error.new("the app exited")
    end
    words = reply.split(' ')
    raise Error.new("worker: #{reply.lchop("error ")}") unless words.shift? == "ok"
    words
  rescue ex : IO::Error
    @gone = true
    raise Error.new("the worker went away: #{ex.message}")
  end
end
