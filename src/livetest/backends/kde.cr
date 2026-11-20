require "../backend"
require "../dbus"
require "../kwin"
require "../screenshot"
require "../uinput"

# :nodoc:
# The user's KDE Plasma session: KWin places the window and takes the
# screenshots, input goes through virtual uinput devices, so it takes over
# the real keyboard and pointer.
class Livetest::Backends::KDE < Livetest::Backend
  @bus : DBus
  @kwin : KWin
  @keyboard : UInput::Keyboard
  @pointer : UInput::Pointer
  @app_id = ""
  @client = Rect.new(0, 0, 0, 0)
  @handle = ""
  # global = origin + abs * scale, per axis
  @origin = {0.0, 0.0}
  @scale = {1.0, 1.0}

  def initialize
    @bus = DBus.session
    @kwin = KWin.new(@bus)
    group = begin
      @bus.call("org.kde.keyboard", "/Layouts", "org.kde.KeyboardLayouts", "getLayout").body.first?.as?(UInt32) || 0_u32
    rescue DBus::Error
      0_u32
    end
    super(Keymap.kde(group.to_i32))
    @keyboard = UInput::Keyboard.new
    @pointer = UInput::Pointer.new
    @kwin.watch
    sleep 500.milliseconds # let libinput add the devices
    calibrate
  end

  def grabs_input? : Bool
    true
  end

  def open(app : App, test : Case, timeout : Time::Span) : Nil
    @app_id = app.app_id
    @kwin.wait_window(@app_id, timeout)
    remember(@kwin.place(@app_id, test.x, test.y))
  end

  def focus : Nil
    unless @kwin.window(@app_id).try(&.active)
      @kwin.activate(@app_id)
      sleep 100.milliseconds
      raise Error.new("the window did not get the keyboard focus") unless @kwin.window(@app_id).try(&.active)
    end
    # `#key` goes by the watch's reports, which may lag the activation
    deadline = Time.instant + 500.milliseconds
    until @kwin.active_class == @app_id
      raise Error.new("KWin did not report the window's activation") if Time.instant >= deadline
      sleep 10.milliseconds
    end
  end

  def shot : Image
    popups = @kwin.popups(@handle).map { |w| {w.id, w.buffer} }
    Screenshot.window(@bus, @handle, @client, popups)
  end

  def resize(width : Int32, height : Int32) : Nil
    remember(@kwin.resize(@app_id, width, height))
  end

  def close_window : Nil
    @kwin.close(@app_id)
  end

  def title : String?
    @kwin.window(@app_id).try(&.caption)
  end

  # Raises before a press when another program's window has the focus,
  # so no key reaches it; `#finish` releases what is held.
  def key(code : UInt16, down : Bool) : Nil
    if down
      active = @kwin.active_class
      unless active == @app_id
        raise Error.new("the window lost the keyboard focus to #{active.empty? ? "no window" : active}")
      end
      @keyboard.press(code)
    else
      @keyboard.release(code)
    end
  end

  def move(x : Int32, y : Int32) : Nil
    @pointer.move(*device(@client.x + x, @client.y + y))
  end

  def button(code : UInt16, down : Bool) : Nil
    down ? @pointer.press(code) : @pointer.release(code)
  end

  def scroll(dy : Int32, dx : Int32) : Nil
    @pointer.scroll(dy, dx)
  end

  # wl-clipboard before 2.3.0 lacks KWin's ext-data-control protocol: its
  # tools take the focus with a popup surface, so the window gets it back.
  def clipboard : String
    super.tap { focus }
  end

  def copy(text : String) : Nil
    super
    focus
  end

  def finish(app : App) : Nil
    @keyboard.release_all
    @pointer.release_all
    @kwin.close(@app_id) unless app.exited?
  end

  def close : Nil
    @keyboard.release_all
    @pointer.release_all
    @keyboard.close
    @pointer.close
    @kwin.cleanup
    @bus.close
  end

  private def remember(w : KWin::Window) : Nil
    @client = w.client
    @handle = w.id
  end

  # KWin maps an absolute device linearly onto the desktop's bounding box;
  # the mapping is checked at three points, retried when the cursor was
  # disturbed.
  private def calibrate : Nil
    desktop = @kwin.desktop
    span = (UInput::ABS_MAX + 1).to_f
    @scale = {desktop.width / span, desktop.height / span}
    @origin = {desktop.x.to_f, desktop.y.to_f}
    points = { {desktop.x + desktop.width // 4, desktop.y + desktop.height // 4},
              {desktop.x + desktop.width * 3 // 4, desktop.y + desktop.height * 3 // 4},
              {desktop.x + desktop.width // 2, desktop.y + desktop.height // 2} }
    miss = nil
    3.times do
      miss = points.each do |(x, y)|
        got = probe(*device(x, y))
        break {x, y, got} unless (got[0] - x).abs <= 1 && (got[1] - y).abs <= 1
      end
      return if miss.nil?
    end
    if m = miss
      raise Error.new("pointer calibration is off: wanted #{m[0]},#{m[1]}, got #{m[2][0]},#{m[2][1]}")
    end
  end

  # Moves to device coordinates and returns the cursor once it has moved
  # and come to rest.
  private def probe(x : Int32, y : Int32) : {Int32, Int32}
    before = @kwin.cursor
    # the kernel drops a value equal to the device's last one, so step off
    # the target first to make a retry move again
    @pointer.move(x + 1, y + 1)
    sleep 8.milliseconds
    @pointer.move(x, y)
    last = before
    moved = false
    20.times do
      sleep 50.milliseconds
      now = @kwin.cursor
      moved ||= now != before
      return now if moved && now == last
      last = now
    end
    last
  end

  private def device(x : Int32, y : Int32) : {Int32, Int32}
    {((x + 0.5 - @origin[0]) / @scale[0]).round.to_i32, ((y + 0.5 - @origin[1]) / @scale[1]).round.to_i32}
  end
end
