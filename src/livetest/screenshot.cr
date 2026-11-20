require "./dbus"
require "./image"

# :nodoc:
# Captures a window and its popups through KWin's `org.kde.KWin.ScreenShot2`. KWin only
# answers executables listed in a desktop file with
# `X-KDE-DBUS-Restricted-Interfaces=org.kde.KWin.ScreenShot2`; see
# `Livetest::Setup`.
module Livetest::Screenshot
  class Error < Exception
  end

  # QImage::Format values KWin may send.
  private FORMAT_RGB32        =  4
  private FORMAT_ARGB32       =  5
  private FORMAT_ARGB32_PRE   =  6
  private FORMAT_RGB888       = 13
  private FORMAT_RGBX8888     = 16
  private FORMAT_RGBA8888     = 17
  private FORMAT_RGBA8888_PRE = 18
  private FORMAT_RGBX64       = 25
  private FORMAT_RGBA64       = 26
  private FORMAT_RGBA64_PRE   = 27
  private FORMAT_BGR888       = 29

  # The formats whose color is not premultiplied by alpha.
  private STRAIGHT_ALPHA = {FORMAT_ARGB32, FORMAT_RGBA8888, FORMAT_RGBA64}

  # Returns the client area of the window with KWin internal id *handle*,
  # without decoration, shadow or cursor, at native resolution, composited
  # over black. Each of *popups* (KWin internal id and buffer area in
  # global logical coordinates, bottom first) is captured with its
  # client-side shadow and composited over it at its place relative to
  # *client*, the window's client area: KWin captures a window without its
  # popup windows, while grim captures the composited output; compositing
  # makes both modes match the same goldens.
  def self.window(bus : DBus, handle : String, client : Rect, popups : Array({String, Rect}) = [] of {String, Rect},
                  timeout : Time::Span = 5.seconds) : Image
    image = capture(bus, handle, false, timeout)
    scale = client.width > 0 ? image.width / client.width : 1.0
    popups.each do |(id, rect)|
      image.over(capture(bus, id, true, timeout), ((rect.x - client.x) * scale).round.to_i32,
        ((rect.y - client.y) * scale).round.to_i32)
    end
    image.opaque!
  end

  # Returns the client area of the window with KWin internal id *handle*,
  # or its whole buffer with *shadow*, with premultiplied alpha.
  private def self.capture(bus : DBus, handle : String, shadow : Bool, timeout : Time::Span) : Image
    options = {
      "include-decoration" => false.as(DBus::Value),
      "include-shadow"     => shadow.as(DBus::Value),
      "include-cursor"     => false.as(DBus::Value),
      "native-resolution"  => true.as(DBus::Value),
    } of String => DBus::Value
    reader, writer = IO.pipe
    data = Channel(Bytes).new(1)
    spawn do
      data.send(reader.getb_to_end)
    rescue IO::Error
      data.send(Bytes.empty)
    ensure
      reader.close
    end
    begin
      reply = bus.call("org.kde.KWin", "/org/kde/KWin/ScreenShot2", "org.kde.KWin.ScreenShot2", "CaptureWindow",
        "sa{sv}h", [handle, options, DBus::UnixFd.new(writer.fd)] of DBus::Value, timeout)
    rescue ex : DBus::Error
      writer.close
      raise Error.new("KWin refused the screenshot (run `#{File.basename(PROGRAM_NAME)} setup`?): #{ex.message}")
    end
    writer.close
    meta = reply.body.first?.try(&.as?(Hash(String, DBus::Value))) || raise Error.new("bad ScreenShot2 reply")
    raw = select
    when bytes = data.receive then bytes
    when timeout(timeout) then raise Error.new("screenshot data did not arrive")
    end
    decode(raw, meta)
  end

  private def self.decode(raw : Bytes, meta : Hash(String, DBus::Value)) : Image
    width = uint(meta, "width")
    height = uint(meta, "height")
    stride = uint(meta, "stride")
    format = uint(meta, "format")
    raise Error.new("short screenshot data (#{raw.size} for #{stride}x#{height})") if raw.size < stride * height
    image = Image.new(width, height)
    dst = image.pixels
    height.times do |y|
      row = raw[y * stride, stride]
      width.times do |x|
        o = (y * width + x) * 4
        r, g, b, a = case format
                     when FORMAT_RGB32, FORMAT_ARGB32, FORMAT_ARGB32_PRE
                       i = x * 4
                       {row[i + 2], row[i + 1], row[i], format == FORMAT_RGB32 ? 255_u8 : row[i + 3]}
                     when FORMAT_RGBX8888, FORMAT_RGBA8888, FORMAT_RGBA8888_PRE
                       i = x * 4
                       {row[i], row[i + 1], row[i + 2], format == FORMAT_RGBX8888 ? 255_u8 : row[i + 3]}
                     when FORMAT_RGB888
                       i = x * 3
                       {row[i], row[i + 1], row[i + 2], 255_u8}
                     when FORMAT_BGR888
                       i = x * 3
                       {row[i + 2], row[i + 1], row[i], 255_u8}
                     when FORMAT_RGBX64, FORMAT_RGBA64, FORMAT_RGBA64_PRE
                       i = x * 8
                       {row[i + 1], row[i + 3], row[i + 5], format == FORMAT_RGBX64 ? 255_u8 : row[i + 7]}
                     else
                       raise Error.new("unsupported screenshot format #{format}")
                     end
        if a < 255 && STRAIGHT_ALPHA.includes?(format)
          r, g, b = {r, g, b}.map { |c| (c.to_u32 * a // 255).to_u8 }
        end
        dst[o] = r
        dst[o + 1] = g
        dst[o + 2] = b
        dst[o + 3] = a
      end
    end
    image
  end

  private def self.uint(meta : Hash(String, DBus::Value), key : String) : Int32
    v = meta[key]?
    v = v.value if v.is_a?(DBus::Variant)
    case v
    when UInt32, Int32, UInt64, Int64 then v.to_i32
    else                                   raise Error.new("ScreenShot2 reply lacks #{key}")
    end
  end
end
