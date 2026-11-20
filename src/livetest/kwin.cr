require "json"
require "file_utils"
require "./dbus"
require "./image"

# :nodoc:
# Drives KWin through its D-Bus scripting interface. Each request is a
# temporary script that answers with JSON through `callDBus` to the name
# this process owns.
class Livetest::KWin
  class Error < Exception
  end

  # A window as KWin reports it; *frame* includes decorations, *client* not,
  # *buffer* is its surface including client-side shadows.
  record Window, id : String, caption : String, pid : Int64, frame : Rect, client : Rect, buffer : Rect,
    active : Bool

  private SERVICE   = "org.kde.KWin"
  private INTERFACE = "org.livetest.Harness"

  getter bus : DBus

  @token = 0
  @dir : String
  @name : String
  # The plugin name of the `#watch` script, nil before it runs.
  @watch : String? = nil
  # The resource class of the active window as `#watch` last reported it.
  @active = ""

  def initialize(@bus : DBus, @timeout : Time::Span = 5.seconds)
    @name = "org.livetest.p#{Process.pid}"
    @bus.request_name(@name)
    @dir = File.join(Dir.tempdir, "livetest-#{Process.pid}")
    Dir.mkdir_p(@dir)
  end

  def cleanup : Nil
    @watch.try { |plugin| unload(plugin) }
    @watch = nil
    FileUtils.rm_rf(@dir)
  end

  # Starts a script that reports every window activation, so that
  # `#active_class` follows the active window without a request.
  def watch : Nil
    return if @watch
    plugin = "livetest-#{Process.pid}-watch"
    path = File.join(@dir, "#{plugin}.js")
    File.write(path, <<-JS)
      (function () {
        function report() {
          var w = workspace.activeWindow;
          callDBus(#{@name.to_json}, "/", #{INTERFACE.to_json}, "activated", w ? String(w.resourceClass) : "");
        }
        workspace.windowActivated.connect(report);
        report();
      })();
      JS
    begin
      @bus.call(SERVICE, "/Scripting", "org.kde.kwin.Scripting", "loadScript", "ss", [path, plugin] of DBus::Value)
      @bus.call(SERVICE, "/Scripting", "org.kde.kwin.Scripting", "start")
    ensure
      File.delete?(path)
    end
    @watch = plugin
  end

  # Returns the resource class of the active window ("" for none), from
  # the reports of `#watch` that have arrived; never blocks.
  def active_class : String
    @bus.poll
    while message = @bus.next?
      dispatch(message, 0)
    end
    @active
  end

  # Runs *body*, a JavaScript function body, inside KWin and returns what it
  # returns. `find(cls)` returns the newest window with that resource class
  # or null, `info(w)` describes a window.
  def eval(body : String) : JSON::Any
    @token += 1
    token = @token
    plugin = "livetest-#{Process.pid}-#{token}"
    path = File.join(@dir, "#{plugin}.js")
    File.write(path, script(body, token))
    begin
      @bus.call(SERVICE, "/Scripting", "org.kde.kwin.Scripting", "loadScript", "ss", [path, plugin] of DBus::Value)
      @bus.call(SERVICE, "/Scripting", "org.kde.kwin.Scripting", "start")
      result = await(token)
    ensure
      unload(plugin)
      File.delete?(path)
    end
    if error = result["error"]?.try(&.as_s?)
      raise Error.new("KWin script: #{error}")
    end
    result["value"]
  end

  private def await(token : Int32) : JSON::Any
    deadline = Time.instant + @timeout
    loop do
      raise Error.new("KWin script did not answer") if Time.instant >= deadline
      message = begin
        @bus.next
      rescue IO::TimeoutError
        raise Error.new("KWin script did not answer")
      end
      dispatch(message, token).try { |result| return result }
    end
  end

  # Answers *message*, records a `#watch` report and returns the result of
  # the script numbered *token*.
  private def dispatch(message : DBus::Message, token : Int32) : JSON::Any?
    return unless message.kind.method_call?
    @bus.reply(message)
    return unless message.interface == INTERFACE
    args = message.body
    case message.member
    when "activated"
      @active = args.first?.as?(String) || ""
    when "result"
      return JSON.parse(args[1].as(String)) if args.size == 2 && args[0] == token.to_s
    end
    nil
  end

  private def unload(plugin : String) : Nil
    @bus.call(SERVICE, "/Scripting", "org.kde.kwin.Scripting", "unloadScript", "s", [plugin] of DBus::Value)
  rescue DBus::Error
  end

  private def script(body : String, token : Int32) : String
    <<-JS
    (function () {
      function rect(r) { return {x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height)}; }
      function find(cls) {
        var list = workspace.windowList(), found = null;
        for (var i = 0; i < list.length; i++) if (list[i].resourceClass == cls) found = list[i];
        return found;
      }
      function info(w) {
        return {id: String(w.internalId), caption: String(w.caption), pid: w.pid,
                frame: rect(w.frameGeometry), client: rect(w.clientGeometry), buffer: rect(w.bufferGeometry),
                active: w.active};
      }
      var out;
      try { var v = (function () { #{body} })(); out = {value: v === undefined ? null : v}; }
      catch (e) { out = {error: String(e)}; }
      callDBus(#{@name.to_json}, "/", #{INTERFACE.to_json}, "result", #{token.to_s.to_json}, JSON.stringify(out));
    })();
    JS
  end

  # Returns the newest window whose resource class (Wayland app id) is
  # *cls*: after a pane is torn off, the torn-off one.
  def window(cls : String) : Window?
    v = eval("var w = find(#{cls.to_json}); return w ? info(w) : null;")
    v.raw.nil? ? nil : parse_window(v)
  end

  # Returns the windows transient for the window with internal id *id*,
  # directly or through others (popup menus and their submenus), parents
  # before their children.
  def popups(id : String) : Array(Window)
    v = eval(<<-JS)
      var list = workspace.windowList(), out = [];
      for (var i = 0; i < list.length; i++) {
        var depth = 0, p = list[i].transientFor;
        while (p && String(p.internalId) != #{id.to_json}) { p = p.transientFor; depth++; }
        if (p) out.push({depth: depth, window: info(list[i])});
      }
      out.sort(function (a, b) { return a.depth - b.depth; });
      return out.map(function (e) { return e.window; });
      JS
    v.as_a.map { |w| parse_window(w) }
  end

  # Polls for the window of *cls* until *timeout*.
  def wait_window(cls : String, timeout : Time::Span) : Window
    deadline = Time.instant + timeout
    loop do
      if w = window(cls)
        return w
      end
      raise Error.new("no window with app id #{cls} after #{timeout.total_seconds}s") if Time.instant >= deadline
      sleep 100.milliseconds
    end
  end

  # Activates the window, keeps it above others and moves its client area
  # to *x*, *y*.
  def place(cls : String, x : Int32, y : Int32) : Window
    parse_window(eval(<<-JS))
      var w = find(#{cls.to_json});
      if (!w) throw "no window " + #{cls.to_json};
      w.minimized = false;
      w.keepAbove = true;
      var f = w.frameGeometry, c = w.clientGeometry;
      w.frameGeometry = {x: #{x} - (c.x - f.x), y: #{y} - (c.y - f.y), width: f.width, height: f.height};
      workspace.activeWindow = w;
      return info(w);
      JS
  end

  # Activates the window.
  def activate(cls : String) : Nil
    eval(<<-JS)
      var w = find(#{cls.to_json});
      if (!w) throw "no window " + #{cls.to_json};
      workspace.activeWindow = w;
      JS
  end

  # Resizes the client area to *width* by *height* pixels.
  def resize(cls : String, width : Int32, height : Int32) : Window
    parse_window(eval(<<-JS))
      var w = find(#{cls.to_json});
      if (!w) throw "no window " + #{cls.to_json};
      var f = w.frameGeometry, c = w.clientGeometry;
      w.frameGeometry = {x: f.x, y: f.y, width: #{width} + (f.width - c.width), height: #{height} + (f.height - c.height)};
      return info(w);
      JS
  end

  # Asks the window to close.
  def close(cls : String) : Nil
    eval("var w = find(#{cls.to_json}); if (w) w.closeWindow();")
  end

  # Returns the pointer position in global logical coordinates.
  def cursor : {Int32, Int32}
    v = eval("var p = workspace.cursorPos; return [p.x, p.y];")
    {number(v[0]), number(v[1])}
  end

  # Returns the bounding box of all outputs in logical coordinates.
  def desktop : Rect
    parse_rect(eval("return rect(workspace.virtualScreenGeometry);"))
  end

  private def parse_window(v : JSON::Any) : Window
    Window.new(v["id"].as_s, v["caption"].as_s, number(v["pid"]).to_i64,
      parse_rect(v["frame"]), parse_rect(v["client"]), parse_rect(v["buffer"]), v["active"].as_bool)
  end

  private def parse_rect(v : JSON::Any) : Rect
    Rect.new(number(v["x"]), number(v["y"]), number(v["width"]), number(v["height"]))
  end

  private def number(v : JSON::Any) : Int32
    v.as_i? || v.as_f.round.to_i32
  end
end
