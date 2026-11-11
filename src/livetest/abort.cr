require "./uinput"

# :nodoc:
# Watches the real keyboards for Escape pressed three times within a second
# and calls the handler; the harness's own virtual devices are ignored.
class Livetest::Abort
  private KEY_ESC = 1_u16
  private PRESSES =     3
  private WINDOW  = 1.second
  private EVENT   = 24 # struct input_event on 64-bit Linux

  @presses = Deque(Time::Instant).new
  @files = [] of IO::FileDescriptor
  getter devices = 0

  def initialize(&@handler : ->)
  end

  # Starts watching every readable `/dev/input/event*` device.
  def start : Nil
    Dir.glob("/dev/input/event*").sort.each do |path|
      fd = LibC.open(path, LibC::O_RDONLY | LibC::O_NONBLOCK | LibC::O_CLOEXEC)
      next if fd < 0
      name = device_name(fd)
      if name.starts_with?(UInput::NAME_PREFIX)
        LibC.close(fd)
        next
      end
      io = IO::FileDescriptor.new(fd)
      @files << io
      @devices += 1
      spawn watch(io)
    end
  end

  def stop : Nil
    @files.each { |io| io.close rescue nil }
    @files.clear
  end

  private def device_name(fd : Int32) : String
    buf = Bytes.new(256)
    request = 0x80004506_u64 | (buf.size.to_u64 << 16) # EVIOCGNAME(256)
    n = UInput::C.ioctl(fd, request, buf.to_unsafe)
    n > 0 ? String.new(buf[0, n]).rstrip('\0') : ""
  end

  private def watch(io : IO::FileDescriptor) : Nil
    event = Bytes.new(EVENT)
    loop do
      io.read_fully(event)
      type = IO::ByteFormat::LittleEndian.decode(UInt16, event[16, 2])
      code = IO::ByteFormat::LittleEndian.decode(UInt16, event[18, 2])
      value = IO::ByteFormat::LittleEndian.decode(Int32, event[20, 4])
      escape if type == UInput::EV_KEY && code == KEY_ESC && value == 1
    end
  rescue IO::Error
  end

  private def escape : Nil
    now = Time.instant
    @presses << now
    while @presses.first < now - WINDOW
      @presses.shift
    end
    @handler.call if @presses.size >= PRESSES
  end
end
