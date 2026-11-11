require "socket"
require "uri"

# :nodoc:
# A D-Bus client on the session bus: EXTERNAL authentication with Unix fd
# passing, typed method calls, an owned name and replies to the method
# calls sent to it. Marshals the complete types of signatures made of
# `y b n q i u x t d s o g h v`, arrays and dictionaries with basic keys.
class Livetest::DBus
  class Error < Exception
  end

  # A Unix file descriptor argument (`h`): sent out of band, kept open.
  record UnixFd, fd : Int32

  # A variant argument (`v`) with an explicit *signature*.
  class Variant
    getter signature : String
    getter value : Value

    def initialize(@signature : String, @value : Value)
    end
  end

  alias Value = String | Bool | UInt8 | Int16 | UInt16 | Int32 | UInt32 | Int64 | UInt64 | Float64 |
                UnixFd | Variant | Array(Value) | Hash(String, Value)

  enum Kind : UInt8
    Invalid
    MethodCall
    MethodReturn
    Error
    Signal
  end

  record Message, kind : Kind, serial : UInt32, reply_serial : UInt32, flags : UInt8,
    sender : String?, path : String?, interface : String?, member : String?, body : Array(Value)

  private FIELD_PATH         = 1_u8
  private FIELD_INTERFACE    = 2_u8
  private FIELD_MEMBER       = 3_u8
  private FIELD_ERROR_NAME   = 4_u8
  private FIELD_REPLY_SERIAL = 5_u8
  private FIELD_DESTINATION  = 6_u8
  private FIELD_SENDER       = 7_u8
  private FIELD_SIGNATURE    = 8_u8
  private FIELD_UNIX_FDS     = 9_u8

  private NO_REPLY_EXPECTED = 1_u8
  private MSG_DONTWAIT      = 0x40

  BUS = {"org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus"}

  getter unique_name : String = ""

  @serial = 0_u32
  @buf = IO::Memory.new
  @pending = Deque(Message).new

  private def initialize(@socket : UNIXSocket)
  end

  def close : Nil
    @socket.close
  rescue IO::Error
  end

  # Connects to the session bus, negotiates fd passing and says Hello.
  def self.session(timeout : Time::Span = 5.seconds) : DBus
    path = session_path || raise Error.new("no D-Bus session bus (DBUS_SESSION_BUS_ADDRESS)")
    socket = UNIXSocket.new(path)
    socket.read_timeout = timeout
    socket.write_timeout = timeout
    bus = new(socket)
    bus.authenticate
    # `#poll` reads the socket itself: nothing may wait in a read buffer
    socket.read_buffering = false
    bus.hello
    bus
  rescue ex : IO::Error | Socket::Error
    raise Error.new("D-Bus: #{ex.message}")
  end

  private def self.session_path : String?
    if address = ENV["DBUS_SESSION_BUS_ADDRESS"]?
      address.split(';').each do |entry|
        transport, _, params = entry.partition(':')
        next unless transport == "unix"
        params.split(',').each do |param|
          k, _, v = param.partition('=')
          return URI.decode(v) if k == "path"
        end
      end
      nil
    elsif dir = ENV["XDG_RUNTIME_DIR"]?
      File.join(dir, "bus")
    end
  end

  protected def authenticate : Nil
    uid = LibC.getuid.to_s.to_slice.hexstring
    @socket.write_byte(0_u8)
    @socket << "AUTH EXTERNAL " << uid << "\r\n"
    @socket.flush
    line = @socket.gets || raise Error.new("D-Bus: no reply to AUTH")
    raise Error.new("D-Bus: authentication failed") unless line.starts_with?("OK ")
    @socket << "NEGOTIATE_UNIX_FD\r\n"
    @socket.flush
    line = @socket.gets || raise Error.new("D-Bus: no reply to NEGOTIATE_UNIX_FD")
    raise Error.new("D-Bus: the bus does not pass file descriptors") unless line.starts_with?("AGREE_UNIX_FD")
    @socket << "BEGIN\r\n"
    @socket.flush
  end

  protected def hello : Nil
    reply = call(*BUS, "Hello")
    @unique_name = reply.body.first.as(String)
  end

  # Owns *name*; raises when another connection has it.
  def request_name(name : String) : Nil
    reply = call(*BUS, "RequestName", "su", [name, 4_u32] of Value)
    code = reply.body.first.as(UInt32)
    raise Error.new("D-Bus: cannot own #{name} (#{code})") unless code == 1 || code == 4
  end

  # Calls a method and returns its reply; raises on an error reply.
  def call(destination : String, path : String, interface : String, member : String,
           signature : String = "", args : Array(Value) = [] of Value, timeout : Time::Span? = nil) : Message
    wait(send_call(destination, path, interface, member, signature, args), timeout)
  end

  # Sends a method call without waiting; returns its serial.
  def send_call(destination : String, path : String, interface : String, member : String,
                signature : String = "", args : Array(Value) = [] of Value) : UInt32
    fds = [] of Int32
    body = Marshal.new(fds)
    i = 0
    args.each { |a| i = body.put(signature, i, a) }
    raise Error.new("D-Bus: #{args.size} arguments for signature #{signature}") unless i == signature.size
    fields = [{FIELD_PATH, 'o', path}, {FIELD_INTERFACE, 's', interface}, {FIELD_MEMBER, 's', member},
              {FIELD_DESTINATION, 's', destination}] of {UInt8, Char, String | UInt32}
    fields << {FIELD_SIGNATURE, 'g', signature} unless signature.empty?
    fields << {FIELD_UNIX_FDS, 'u', fds.size.to_u32} unless fds.empty?
    send(Kind::MethodCall, 0_u8, fields, body, fds)
  end

  # Replies to *call* with *args* of *signature*, unless it expects no reply.
  def reply(call : Message, signature : String = "", args : Array(Value) = [] of Value) : Nil
    return if call.flags & NO_REPLY_EXPECTED != 0
    body = Marshal.new([] of Int32)
    i = 0
    args.each { |a| i = body.put(signature, i, a) }
    fields = [{FIELD_REPLY_SERIAL, 'u', call.serial}] of {UInt8, Char, String | UInt32}
    call.sender.try { |s| fields << {FIELD_DESTINATION, 's', s} }
    fields << {FIELD_SIGNATURE, 'g', signature} unless signature.empty?
    send(Kind::MethodReturn, 0_u8, fields, body, [] of Int32)
  end

  private def send(kind : Kind, flags : UInt8, fields : Array({UInt8, Char, String | UInt32}),
                   body : Marshal, fds : Array(Int32)) : UInt32
    @serial += 1
    head = Marshal.new([] of Int32)
    io = head.io
    io.write_byte('l'.ord.to_u8)
    io.write_byte(kind.value)
    io.write_byte(flags)
    io.write_byte(1_u8)
    io.write_bytes(body.io.size.to_u32, IO::ByteFormat::LittleEndian)
    io.write_bytes(@serial, IO::ByteFormat::LittleEndian)
    array = IO::Memory.new
    fields_marshal = Marshal.new([] of Int32, array, 16)
    fields.each do |(code, type, value)|
      fields_marshal.pad(8)
      array.write_byte(code)
      fields_marshal.put_signature(type.to_s)
      fields_marshal.put(type.to_s, 0, value.as(Value))
    end
    io.write_bytes(array.size.to_u32, IO::ByteFormat::LittleEndian)
    io.write(array.to_slice)
    head.pad(8)
    io.write(body.io.to_slice)
    write_message(io.to_slice, fds)
    @serial
  end

  private def write_message(data : Bytes, fds : Array(Int32)) : Nil
    if fds.empty?
      @socket.write(data)
      @socket.flush
      return
    end
    @socket.flush
    iov = LibC::Iovec.new(iov_base: data.to_unsafe.as(Void*), iov_len: data.size)
    space = sizeof(LibC::Cmsghdr) + fds.size * sizeof(Int32)
    control = Bytes.new((space + 7) // 8 * 8)
    cmsg = control.to_unsafe.as(LibC::Cmsghdr*)
    cmsg.value.cmsg_len = space
    cmsg.value.cmsg_level = LibC::SOL_SOCKET
    cmsg.value.cmsg_type = 1 # SCM_RIGHTS
    fd_data = (control.to_unsafe + sizeof(LibC::Cmsghdr)).as(Int32*)
    fds.each_with_index { |fd, i| fd_data[i] = fd }
    msg = LibC::Msghdr.new
    msg.msg_iov = pointerof(iov)
    msg.msg_iovlen = 1
    msg.msg_control = control.to_unsafe.as(Void*)
    msg.msg_controllen = control.size
    sent = LibC.sendmsg(@socket.fd, pointerof(msg), 0)
    raise Error.new("D-Bus: sendmsg: #{Errno.value.message}") if sent < 0
    raise Error.new("D-Bus: short sendmsg") unless sent == data.size
  end

  # Blocks for the reply to *serial*; queues the other messages for `#next`.
  def wait(serial : UInt32, timeout : Time::Span? = nil) : Message
    deadline = timeout.try { |t| Time.instant + t }
    loop do
      if index = @pending.index { |m| m.reply_serial == serial && (m.kind.method_return? || m.kind.error?) }
        m = @pending.delete_at(index)
        raise Error.new("D-Bus: #{m.member}: #{m.body.first? || "error"}") if m.kind.error?
        return m
      end
      if deadline && Time.instant >= deadline
        raise Error.new("D-Bus: no reply to call #{serial}")
      end
      read_more
    end
  end

  # Returns the next queued or incoming message that is not a reply.
  def next : Message
    loop do
      if index = @pending.index { |m| m.kind.method_call? || m.kind.signal? }
        return @pending.delete_at(index)
      end
      read_more
    end
  end

  # Returns the next queued message that is not a reply, nil when none is
  # queued; `#poll` queues the messages that arrived.
  def next? : Message?
    if index = @pending.index { |m| m.kind.method_call? || m.kind.signal? }
      @pending.delete_at(index)
    end
  end

  # Queues the messages that have arrived, without blocking.
  def poll : Nil
    chunk = Bytes.new(16384)
    loop do
      n = LibC.recv(@socket.fd, chunk.to_unsafe.as(Void*), LibC::SizeT.new(chunk.size), MSG_DONTWAIT)
      if n < 0
        break if Errno.value.in?(Errno::EAGAIN, Errno::EINTR)
        raise Error.new("D-Bus: #{Errno.value.message}")
      end
      raise Error.new("D-Bus: connection closed") if n == 0
      @buf.seek(0, IO::Seek::End)
      @buf.write(chunk[0, n])
    end
    split_messages
  end

  private def read_more : Nil
    chunk = Bytes.new(16384)
    n = @socket.read(chunk)
    raise Error.new("D-Bus: connection closed") if n == 0
    @buf.seek(0, IO::Seek::End)
    @buf.write(chunk[0, n])
    split_messages
  end

  private def split_messages : Nil
    data = @buf.to_slice
    pos = 0
    while data.size - pos >= 16
      format = data[pos] == 'B'.ord ? IO::ByteFormat::BigEndian : IO::ByteFormat::LittleEndian
      body_len = format.decode(UInt32, data[pos + 4, 4]).to_i32
      fields_len = format.decode(UInt32, data[pos + 12, 4]).to_i32
      total = 16 + (fields_len + 7) // 8 * 8 + body_len
      break if data.size - pos < total
      begin
        m = parse(data[pos, total], format, fields_len)
        @pending << m unless m.kind.signal? && m.interface == "org.freedesktop.DBus"
      rescue Error | IndexError
      end
      pos += total
    end
    rest = data[pos..].dup
    @buf = IO::Memory.new
    @buf.write(rest)
  end

  private def parse(msg : Bytes, format : IO::ByteFormat, fields_len : Int32) : Message
    kind = Kind.from_value?(msg[1]) || Kind::Invalid
    flags = msg[2]
    serial = format.decode(UInt32, msg[8, 4])
    reader = Reader.new(msg, format, 12)
    fields = reader.read("a(yv)", 0)[0].as(Array(Value))
    reply_serial = 0_u32
    sender = path = interface = member = nil
    signature = ""
    fields.each do |f|
      pair = f.as(Array(Value))
      value = pair[1].as(Variant).value
      case pair[0].as(UInt8)
      when FIELD_PATH         then path = value.as?(String)
      when FIELD_INTERFACE    then interface = value.as?(String)
      when FIELD_MEMBER       then member = value.as?(String)
      when FIELD_ERROR_NAME   then member = value.as?(String) if kind.error?
      when FIELD_REPLY_SERIAL then reply_serial = value.as?(UInt32) || 0_u32
      when FIELD_SENDER       then sender = value.as?(String)
      when FIELD_SIGNATURE    then signature = value.as?(String) || ""
      end
    end
    reader.pos = 16 + (fields_len + 7) // 8 * 8
    body = [] of Value
    i = 0
    while i < signature.size
      v, i = reader.read(signature, i)
      body << v
    end
    Message.new(kind, serial, reply_serial, flags, sender, path, interface, member, body)
  end

  # The index after the complete type at *sig*[*i*].
  protected def self.skip(sig : String, i : Int32) : Int32
    case sig[i]
    when 'a' then skip(sig, i + 1)
    when '(' then close_of(sig, i, '(', ')') + 1
    when '{' then close_of(sig, i, '{', '}') + 1
    else          i + 1
    end
  end

  private def self.close_of(sig : String, i : Int32, open : Char, close : Char) : Int32
    depth = 0
    j = i
    while j < sig.size
      depth += 1 if sig[j] == open
      depth -= 1 if sig[j] == close
      return j if depth == 0
      j += 1
    end
    raise Error.new("D-Bus: unbalanced signature #{sig}")
  end

  protected def self.alignment(type : Char) : Int32
    case type
    when 'y', 'g', 'v'           then 1
    when 'n', 'q'                then 2
    when 'd', 't', 'x', '(', '{' then 8
    else                              4
    end
  end

  protected def self.signature_of(v : Value) : String
    case v
    in String              then "s"
    in Bool                then "b"
    in UInt8               then "y"
    in Int16               then "n"
    in UInt16              then "q"
    in Int32               then "i"
    in UInt32              then "u"
    in Int64               then "x"
    in UInt64              then "t"
    in Float64             then "d"
    in UnixFd              then "h"
    in Variant             then "v"
    in Array(Value)        then "a" + (v.first?.try { |e| signature_of(e) } || "v")
    in Hash(String, Value) then "a{sv}"
    end
  end

  # Little-endian marshalling into a buffer that starts at offset *base*
  # of its message.
  private class Marshal
    getter io : IO::Memory

    def initialize(@fds : Array(Int32), @io = IO::Memory.new, @base = 0)
    end

    def pad(n : Int32) : Nil
      at = @io.size + @base
      ((at + n - 1) // n * n - at).times { @io.write_byte(0_u8) }
    end

    def put_signature(s : String) : Nil
      @io.write_byte(s.bytesize.to_u8)
      @io << s
      @io.write_byte(0_u8)
    end

    # Writes *v* as the complete type at *sig*[*i*]; returns the index after it.
    def put(sig : String, i : Int32, value : Value) : Int32
      v = value.as(Value)
      case t = sig[i]
      when 's', 'o'
        s = v.as(String)
        fixed(s.bytesize.to_u32)
        @io << s
        @io.write_byte(0_u8)
      when 'g' then put_signature(v.as(String))
      when 'y' then @io.write_byte(v.as(UInt8))
      when 'b' then fixed(v.as(Bool) ? 1_u32 : 0_u32)
      when 'n' then fixed(v.as(Int16))
      when 'q' then fixed(v.as(UInt16))
      when 'i' then fixed(v.as(Int32))
      when 'u' then fixed(v.as(UInt32))
      when 'x' then fixed(v.as(Int64))
      when 't' then fixed(v.as(UInt64))
      when 'd' then fixed(v.as(Float64))
      when 'h'
        @fds << v.as(UnixFd).fd
        fixed((@fds.size - 1).to_u32)
      when 'v'
        var = v.is_a?(Variant) ? v : Variant.new(DBus.signature_of(v), v)
        put_signature(var.signature)
        put(var.signature, 0, var.value)
      when '('
        items = v.as(Array(Value))
        pad(8)
        j = i + 1
        items.each { |item| j = put(sig, j, item) }
        return j + 1
      when 'a'
        pad(4)
        at = @io.pos
        fixed(0_u32)
        elem = i + 1
        pad(DBus.alignment(sig[elem]))
        start = @io.size
        if sig[elem] == '{'
          v.as(Hash(String, Value)).each do |k, val|
            pad(8)
            put(sig, elem + 1, k)
            put(sig, elem + 2, val)
          end
        else
          v.as(Array(Value)).each { |item| put(sig, elem, item) }
        end
        len = @io.size - start
        @io.pos = at
        @io.write_bytes(len.to_u32, IO::ByteFormat::LittleEndian)
        @io.seek(0, IO::Seek::End)
        return DBus.skip(sig, elem)
      else
        raise Error.new("D-Bus: unsupported type #{t}")
      end
      i + 1
    end

    private def fixed(v : Int | Float) : Nil
      pad(sizeof(typeof(v)))
      @io.write_bytes(v, IO::ByteFormat::LittleEndian)
    end
  end

  # Reads marshalled values from a message.
  private class Reader
    property pos : Int32

    def initialize(@data : Bytes, @format : IO::ByteFormat, @pos : Int32)
    end

    def align(n : Int32) : Nil
      @pos = (@pos + n - 1) // n * n
    end

    # Reads the complete type at *sig*[*i*]; returns it and the index after it.
    def read(sig : String, i : Int32) : {Value, Int32}
      case t = sig[i]
      when 'a'
        len = fixed(UInt32).to_i32
        elem = i + 1
        align(DBus.alignment(sig[elem]))
        stop = @pos + len
        after = DBus.skip(sig, elem)
        if sig[elem] == '{'
          hash = {} of String => Value
          while @pos < stop
            align(8)
            k, _ = read(sig, elem + 1)
            v, _ = read(sig, DBus.skip(sig, elem + 1))
            hash[k.to_s] = v
          end
          {hash.as(Value), after}
        else
          list = [] of Value
          while @pos < stop
            v, _ = read(sig, elem)
            list << v
          end
          {list.as(Value), after}
        end
      when '('
        align(8)
        list = [] of Value
        j = i + 1
        while sig[j] != ')'
          v, j = read(sig, j)
          list << v
        end
        {list.as(Value), j + 1}
      when 'v'
        s = signature
        v, _ = read(s, 0)
        {Variant.new(s, v).as(Value), i + 1}
      else
        {basic(t), i + 1}
      end
    end

    private def basic(type : Char) : Value
      case type
      when 'y'
        b = @data[@pos]
        @pos += 1
        b
      when 'b' then fixed(UInt32) != 0
      when 'n' then fixed(Int16)
      when 'q' then fixed(UInt16)
      when 'i' then fixed(Int32)
      when 'u' then fixed(UInt32)
      when 'h' then UnixFd.new(fixed(UInt32).to_i32)
      when 'x' then fixed(Int64)
      when 't' then fixed(UInt64)
      when 'd' then fixed(Float64)
      when 's', 'o'
        len = fixed(UInt32).to_i32
        str = String.new(@data[@pos, len])
        @pos += len + 1
        str
      when 'g' then signature
      else          raise Error.new("D-Bus: unsupported type #{type}")
      end
    end

    private def signature : String
      len = @data[@pos].to_i32
      str = String.new(@data[@pos + 1, len])
      @pos += len + 2
      str
    end

    private def fixed(type : T.class) : T forall T
      align(sizeof(T))
      v = @format.decode(type, @data[@pos, sizeof(T)])
      @pos += sizeof(T)
      v
    end
  end
end
