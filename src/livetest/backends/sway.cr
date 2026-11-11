require "file_utils"
require "json"
require "socket"
require "../backend"
require "../wayland"

# :nodoc:
# A nested sway, started once per run: headless, or shown as a window of
# the user's Wayland session. Input goes through Wayland virtual devices, so
# the user's keyboard and pointer stay free; sway's IPC places the window
# and grim takes the screenshots.
class Livetest::Backends::Sway < Livetest::Backend
  WIDTH  = 1600
  HEIGHT = 1000

  private IPC_COMMAND = 0_u32
  private IPC_TREE    = 4_u32

  # sway draws the pointer into the output, so its cursor theme draws every
  # shape as one transparent pixel; `hide_cursor` would also take the
  # pointer focus from the window.
  private CURSOR_THEME = "livetest-none"
  private CURSOR_NAMES = %w(default left_ptr context-menu help pointer progress wait cell crosshair
    text vertical-text alias copy move no-drop not-allowed grab grabbing e-resize n-resize ne-resize
    nw-resize s-resize se-resize sw-resize w-resize ew-resize ns-resize nesw-resize nwse-resize
    col-resize row-resize all-scroll zoom-in zoom-out dnd-ask all-resize)
  # An Xcursor file: its header, one table entry, then one 24 px nominal
  # image chunk of 1x1 transparent pixel.
  private CURSOR_FILE = StaticArray[
    0x72756358_u32, 16_u32, 0x10000_u32, 1_u32,
    0xfffd0002_u32, 24_u32, 28_u32,
    36_u32, 0xfffd0002_u32, 24_u32, 1_u32, 1_u32, 1_u32, 0_u32, 0_u32, 0_u32, 0_u32,
  ]

  @dir : String
  @process : Process
  @socket = ""
  @ipc_path = ""
  @wayland : Wayland? = nil
  @app_id = ""
  @client = Rect.new(0, 0, 0, 0)

  # Starts sway; *show* puts it in a window of the current session.
  def initialize(show : Bool, timeout : Time::Span = 10.seconds)
    super(Keymap.new(nil, nil, nil, nil, 0))
    base = ENV["XDG_RUNTIME_DIR"]?.presence || Dir.tempdir
    @dir = File.join(base, "livetest-#{Process.pid}")
    FileUtils.rm_rf(@dir)
    Dir.mkdir(@dir, 0o700)
    ready = File.join(@dir, "ready")
    icons = File.join(@dir, "icons")
    write_cursor_theme(icons)
    config = File.join(@dir, "sway.cfg")
    File.write(config, config_text(show, ready))
    env = {"XDG_RUNTIME_DIR" => @dir, "WLR_LIBINPUT_NO_DEVICES" => "1", "DISPLAY" => nil,
           "SWAYSOCK" => nil, "I3SOCK" => nil, "XCURSOR_PATH" => icons} of String => String?
    if show
      host = ENV["WAYLAND_DISPLAY"]?.presence || raise Error.new("-S needs a Wayland session")
      host = File.join(base, host) unless host.starts_with?('/')
      env["WAYLAND_DISPLAY"] = host
      env["WLR_BACKENDS"] = "wayland"
    else
      env["WAYLAND_DISPLAY"] = nil
      env["WLR_BACKENDS"] = "headless"
      env["WLR_HEADLESS_OUTPUTS"] = "1"
    end
    log = File.open(File.join(@dir, "sway.log"), "w")
    @process = begin
      Process.new("sway", ["-c", config], env: env, output: log, error: log)
    rescue ex : File::NotFoundError | IO::Error
      raise Error.new("cannot start sway: #{ex.message}")
    ensure
      log.close
    end
    deadline = Time.instant + timeout
    until File.exists?(ready)
      if @process.terminated? || Time.instant >= deadline
        stop_sway
        raise Error.new("sway did not start, see #{File.join(@dir, "sway.log")}")
      end
      sleep 50.milliseconds
    end
    display, @ipc_path = File.read(ready).split
    @socket = display.starts_with?('/') ? display : File.join(@dir, display)
    begin
      @wayland = Wayland.new(@socket, keymap.text)
    rescue ex : Wayland::Error
      close
      raise Error.new(ex.message)
    end
  end

  private def config_text(show : Bool, ready : String) : String
    String.build do |io|
      io << "output * resolution " << WIDTH << 'x' << HEIGHT << " position 0 0 scale 1\n"
      io << "default_border none\ndefault_floating_border none\nfocus_follows_mouse no\n"
      io << "mouse_warping none\nfloating_maximum_size -1 x -1\nxwayland disable\n"
      io << "for_window [app_id=\"^livetest-\"] floating enable\n"
      io << "seat * xcursor_theme " << CURSOR_THEME << " 24\n"
      if show
        # the host's devices get their own seat, so they cannot disturb a case
        io << "seat host attach 0:0:wayland-pointer-seat0\nseat host attach 0:0:wayland-keyboard-seat0\n"
      end
      io << "exec sh -c 'echo \"$WAYLAND_DISPLAY $SWAYSOCK\" > " << ready << ".tmp && mv " << ready << ".tmp " << ready << "'\n"
    end
  end

  def tool_env : Hash(String, String?)
    {"WAYLAND_DISPLAY" => @socket, "DISPLAY" => nil} of String => String?
  end

  def open(app : App, test : Case, timeout : Time::Span) : Nil
    @app_id = app.app_id
    # the window must not open under the pointer the previous case left
    wayland.move(WIDTH - 1, HEIGHT - 1, WIDTH, HEIGHT)
    deadline = Time.instant + timeout
    until node
      raise Error.new("no window with app id #{@app_id} after #{timeout.total_seconds}s") if Time.instant >= deadline
      raise Error.new("the app exited before its window opened") if app.exited?
      sleep 100.milliseconds
    end
    command("floating enable, move absolute position #{test.x} #{test.y}, focus")
    remember
  end

  def focus : Nil
    return if node.try(&.["focused"].as_bool?)
    command("focus")
    sleep 50.milliseconds
  end

  def shot : Image
    png = IO::Memory.new
    err = IO::Memory.new
    geometry = "#{@client.x},#{@client.y} #{@client.width}x#{@client.height}"
    status = Process.run("grim", ["-g", geometry, "-t", "png", "-l", "0", "-"], env: tool_env, output: png, error: err)
    raise Error.new("grim failed: #{err.to_s.strip}") unless status.success?
    png.rewind
    Image.read(png)
  rescue File::NotFoundError
    raise Error.new("grim is missing")
  end

  def resize(width : Int32, height : Int32) : Nil
    command("resize set width #{width} px height #{height} px")
    remember
  end

  def close_window : Nil
    command("kill")
  end

  def title : String?
    node.try(&.["name"].as_s?)
  end

  def key(code : UInt16, down : Bool) : Nil
    wayland.key(code, down)
  end

  def move(x : Int32, y : Int32) : Nil
    wayland.move(@client.x + x, @client.y + y, WIDTH, HEIGHT)
  end

  def button(code : UInt16, down : Bool) : Nil
    wayland.button(code, down)
  end

  def scroll(dy : Int32, dx : Int32) : Nil
    wayland.scroll(dy, dx)
  end

  def finish(app : App) : Nil
    command("kill") unless app.exited? || node.nil?
  rescue Error
  end

  def close : Nil
    @wayland.try(&.close)
    @wayland = nil
    begin
      ipc(IPC_COMMAND, "exit") unless @ipc_path.empty?
    rescue Error
    end
    stop_sway
    FileUtils.rm_rf(@dir)
  end

  private def stop_sway : Nil
    return if @process.terminated?
    50.times do
      return if @process.terminated?
      sleep 20.milliseconds
    end
    @process.signal(Signal::TERM) rescue nil
    @process.wait
  end

  # Writes `CURSOR_THEME` below *icons*.
  private def write_cursor_theme(icons : String) : Nil
    theme = File.join(icons, CURSOR_THEME)
    cursors = File.join(theme, "cursors")
    Dir.mkdir_p(cursors)
    File.write(File.join(theme, "index.theme"), "[Icon Theme]\nName=#{CURSOR_THEME}\n")
    File.open(File.join(cursors, CURSOR_NAMES.first), "w") do |io|
      CURSOR_FILE.each { |v| io.write_bytes(v, IO::ByteFormat::LittleEndian) }
    end
    CURSOR_NAMES.skip(1).each { |name| File.symlink(CURSOR_NAMES.first, File.join(cursors, name)) }
  end

  private def wayland : Wayland
    @wayland || raise Error.new("sway is closed")
  end

  # Sets `@client` from the window's rectangle once sway has applied it.
  private def remember : Nil
    last = nil
    20.times do
      n = node || raise Error.new("the window of #{@app_id} is gone")
      r, w = n["rect"], n["window_rect"]
      rect = Rect.new(r["x"].as_i + w["x"].as_i, r["y"].as_i + w["y"].as_i, w["width"].as_i, w["height"].as_i)
      @client = rect
      return if rect == last
      last = rect
      sleep 30.milliseconds
    end
  end

  private def command(cmd : String) : Nil
    reply = ipc(IPC_COMMAND, "[app_id=\"^#{Regex.escape(@app_id)}$\"] #{cmd}")
    reply.as_a.each do |r|
      raise Error.new("sway: #{cmd}: #{r["error"]?.try(&.as_s) || "failed"}") unless r["success"].as_bool
    end
  end

  # Returns the tree node of the window, nil when there is none.
  private def node : JSON::Any?
    find(ipc(IPC_TREE, ""))
  end

  private def find(n : JSON::Any) : JSON::Any?
    return n if n["app_id"]?.try(&.as_s?) == @app_id
    {"nodes", "floating_nodes"}.each do |key|
      n[key]?.try(&.as_a.each { |c| find(c).try { |f| return f } })
    end
    nil
  end

  private def ipc(type : UInt32, payload : String) : JSON::Any
    UNIXSocket.open(@ipc_path) do |sock|
      sock.write("i3-ipc".to_slice)
      sock.write_bytes(payload.bytesize.to_u32, IO::ByteFormat::LittleEndian)
      sock.write_bytes(type, IO::ByteFormat::LittleEndian)
      sock.write(payload.to_slice)
      sock.flush
      magic = Bytes.new(6)
      sock.read_fully(magic)
      size = sock.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      sock.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      body = Bytes.new(size)
      sock.read_fully(body)
      JSON.parse(String.new(body))
    end
  rescue ex : IO::Error | Socket::Error | JSON::ParseException
    raise Error.new("sway IPC: #{ex.message}")
  end
end
