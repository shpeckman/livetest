require "./keymap"

# :nodoc:
# Minimal libwayland-client binding: enough to bind globals and send
# requests of protocols whose interfaces are described by hand.
@[Link("wayland-client")]
lib LibWl
  struct Message
    name : UInt8*
    signature : UInt8*
    types : Interface**
  end

  struct Interface
    name : UInt8*
    version : Int32
    method_count : Int32
    methods : Message*
    event_count : Int32
    events : Message*
  end

  union Argument
    i : Int32
    u : UInt32
    f : Int32
    s : UInt8*
    o : Void*
    n : UInt32
    a : Void*
    h : Int32
  end

  alias Dispatcher = (Void*, Void*, UInt32, Message*, Argument*) -> Int32

  MARSHAL_FLAG_DESTROY = 1_u32

  $wl_registry_interface : Interface
  $wl_seat_interface : Interface

  fun wl_display_connect(name : UInt8*) : Void*
  fun wl_display_disconnect(display : Void*) : Void
  fun wl_display_roundtrip(display : Void*) : Int32
  fun wl_display_flush(display : Void*) : Int32
  fun wl_proxy_marshal_flags(proxy : Void*, opcode : UInt32, interface : Interface*, version : UInt32,
                             flags : UInt32, ...) : Void*
  fun wl_proxy_add_dispatcher(proxy : Void*, dispatcher : Dispatcher, data : Void*, user_data : Void*) : Int32
  fun wl_proxy_destroy(proxy : Void*) : Void
end

# :nodoc:
# A connection to a Wayland display with a virtual keyboard
# (zwp_virtual_keyboard_v1) and a virtual pointer (zwlr_virtual_pointer_v1)
# on the seat named `seat0`.
class Livetest::Wayland
  class Error < Exception
  end

  private record Global, name : UInt32, interface : String, version : UInt32

  # Interface descriptions, built once; libwayland keeps pointers to them.
  private class Interfaces
    getter keyboard_manager : LibWl::Interface*
    getter keyboard : LibWl::Interface*
    getter pointer_manager : LibWl::Interface*
    getter pointer : LibWl::Interface*

    def initialize
      seat = pointerof(LibWl.wl_seat_interface)
      @keyboard = Pointer(LibWl::Interface).malloc(1)
      @pointer = Pointer(LibWl::Interface).malloc(1)
      @keyboard_manager = Pointer(LibWl::Interface).malloc(1)
      @pointer_manager = Pointer(LibWl::Interface).malloc(1)
      none = Pointer(LibWl::Interface).null
      describe(@keyboard, "zwp_virtual_keyboard_v1", 1, [
        {"keymap", "uhu", [none, none, none]},
        {"key", "uuu", [none, none, none]},
        {"modifiers", "uuuu", [none, none, none, none]},
        {"destroy", "", [] of LibWl::Interface*},
      ])
      describe(@keyboard_manager, "zwp_virtual_keyboard_manager_v1", 1, [
        {"create_virtual_keyboard", "on", [seat, @keyboard]},
      ])
      describe(@pointer, "zwlr_virtual_pointer_v1", 1, [
        {"motion", "uff", [none, none, none]},
        {"motion_absolute", "uuuuu", [none, none, none, none, none]},
        {"button", "uuu", [none, none, none]},
        {"axis", "uuf", [none, none, none]},
        {"frame", "", [] of LibWl::Interface*},
        {"axis_source", "u", [none]},
        {"axis_stop", "uu", [none, none]},
        {"axis_discrete", "uufi", [none, none, none, none]},
        {"destroy", "", [] of LibWl::Interface*},
      ])
      describe(@pointer_manager, "zwlr_virtual_pointer_manager_v1", 1, [
        {"create_virtual_pointer", "?on", [seat, @pointer]},
        {"destroy", "", [] of LibWl::Interface*},
      ])
    end

    private def describe(at : LibWl::Interface*, name : String, version : Int32,
                         requests : Array({String, String, Array(LibWl::Interface*)})) : Nil
      messages = Pointer(LibWl::Message).malloc(requests.size)
      requests.each_with_index do |(req, sig, types), i|
        t = Pointer(LibWl::Interface*).malloc(Math.max(types.size, 1))
        types.each_with_index { |type, j| t[j] = type }
        messages[i] = LibWl::Message.new(name: req.to_unsafe, signature: sig.to_unsafe, types: t)
      end
      at.value = LibWl::Interface.new(name: name.to_unsafe, version: version, method_count: requests.size,
        methods: messages, event_count: 0, events: Pointer(LibWl::Message).null)
    end
  end

  @@interfaces : Interfaces?

  # Registry and seat event handlers; *data* is the boxed connection.
  private GLOBAL = ->(data : Void*, _target : Void*, opcode : UInt32, _msg : LibWl::Message*, args : LibWl::Argument*) do
    if opcode == 0
      Box(Wayland).unbox(data).add_global(Global.new(args[0].u, String.new(args[1].s), args[2].u))
    end
    0
  end

  private SEAT = ->(data : Void*, target : Void*, opcode : UInt32, _msg : LibWl::Message*, args : LibWl::Argument*) do
    Box(Wayland).unbox(data).seat_named(target, String.new(args[0].s)) if opcode == 1
    0
  end

  @display : Void*
  @box = Pointer(Void).null
  @globals = [] of Global
  @seats = [] of {Void*, String}
  @keyboard = Pointer(Void).null
  @pointer = Pointer(Void).null
  @start = Time.instant
  # xkb state of the virtual keyboard: the compositor takes its modifiers
  # from `modifiers` requests only.
  @xkb_context = Pointer(Void).null
  @xkb_keymap = Pointer(Void).null
  @xkb_state = Pointer(Void).null

  # Connects to *socket* (an absolute path) and creates the devices;
  # *keymap* is the keyboard's xkb keymap text.
  def initialize(socket : String, keymap : String)
    ifaces = (@@interfaces ||= Interfaces.new)
    @display = LibWl.wl_display_connect(socket)
    raise Error.new("cannot connect to the Wayland display #{socket}") if @display.null?
    @box = Box.box(self)
    registry = LibWl.wl_proxy_marshal_flags(@display, 1_u32, pointerof(LibWl.wl_registry_interface), 1_u32, 0_u32,
      Pointer(Void).null)
    LibWl.wl_proxy_add_dispatcher(registry, GLOBAL, @box, Pointer(Void).null)
    roundtrip
    kbd_manager = bind(registry, "zwp_virtual_keyboard_manager_v1", ifaces.keyboard_manager)
    ptr_manager = bind(registry, "zwlr_virtual_pointer_manager_v1", ifaces.pointer_manager)
    @globals.select(&.interface.==("wl_seat")).each do |g|
      seat = LibWl.wl_proxy_marshal_flags(registry, 0_u32, pointerof(LibWl.wl_seat_interface), 2_u32, 0_u32,
        g.name, "wl_seat".to_unsafe, 2_u32, Pointer(Void).null)
      LibWl.wl_proxy_add_dispatcher(seat, SEAT, @box, Pointer(Void).null)
    end
    roundtrip
    seat = @seats.find { |(_, n)| n == "seat0" }.try(&.[0]) || raise Error.new("no seat0 on #{socket}")
    @keyboard = LibWl.wl_proxy_marshal_flags(kbd_manager, 0_u32, ifaces.keyboard, 1_u32, 0_u32, seat,
      Pointer(Void).null)
    @pointer = LibWl.wl_proxy_marshal_flags(ptr_manager, 0_u32, ifaces.pointer, 1_u32, 0_u32, seat,
      Pointer(Void).null)
    send_keymap(keymap)
    @xkb_context = Keymap::Xkb.context_new(0)
    @xkb_keymap = Keymap::Xkb.keymap_new_from_string(@xkb_context, keymap, 1, 0)
    raise Error.new("cannot compile the keymap") if @xkb_keymap.null?
    @xkb_state = Keymap::Xkb.state_new(@xkb_keymap)
  end

  protected def add_global(g : Global) : Nil
    @globals << g
  end

  protected def seat_named(seat : Void*, name : String) : Nil
    @seats << {seat, name}
  end

  private def bind(registry : Void*, name : String, iface : LibWl::Interface*) : Void*
    g = @globals.find(&.interface.==(name)) || raise Error.new("the compositor lacks #{name}")
    LibWl.wl_proxy_marshal_flags(registry, 0_u32, iface, 1_u32, 0_u32, g.name, name.to_unsafe, 1_u32,
      Pointer(Void).null)
  end

  # libwayland duplicates the descriptor while marshalling.
  private def send_keymap(text : String) : Nil
    file = File.tempfile("livetest-keymap") do |io|
      io << text
      io.write_byte(0_u8)
    end
    begin
      File.open(file.path) do |io|
        LibWl.wl_proxy_marshal_flags(@keyboard, 0_u32, Pointer(LibWl::Interface).null, 1_u32, 0_u32,
          1_u32, io.fd, (text.bytesize + 1).to_u32)
        roundtrip
      end
    ensure
      file.delete
    end
  end

  private def time : UInt32
    (Time.instant - @start).total_milliseconds.to_u32!
  end

  # Presses or releases the key of evdev code *code*.
  def key(code : UInt16, down : Bool) : Nil
    LibWl.wl_proxy_marshal_flags(@keyboard, 1_u32, Pointer(LibWl::Interface).null, 1_u32, 0_u32,
      time, code.to_u32, down ? 1_u32 : 0_u32)
    Keymap::Xkb.state_update_key(@xkb_state, code.to_u32 + 8, down ? 1 : 0)
    LibWl.wl_proxy_marshal_flags(@keyboard, 2_u32, Pointer(LibWl::Interface).null, 1_u32, 0_u32,
      Keymap::Xkb.state_serialize_mods(@xkb_state, 1), Keymap::Xkb.state_serialize_mods(@xkb_state, 2),
      Keymap::Xkb.state_serialize_mods(@xkb_state, 4), Keymap::Xkb.state_serialize_layout(@xkb_state, 128))
    roundtrip
  end

  # Moves the pointer to *x*, *y* of the *width* x *height* layout.
  def move(x : Int32, y : Int32, width : Int32, height : Int32) : Nil
    # pixel centres on a doubled grid
    LibWl.wl_proxy_marshal_flags(@pointer, 1_u32, Pointer(LibWl::Interface).null, 1_u32, 0_u32,
      time, (x * 2 + 1).to_u32, (y * 2 + 1).to_u32, (width * 2).to_u32, (height * 2).to_u32)
    frame
  end

  def button(code : UInt16, down : Bool) : Nil
    LibWl.wl_proxy_marshal_flags(@pointer, 2_u32, Pointer(LibWl::Interface).null, 1_u32, 0_u32,
      time, code.to_u32, down ? 1_u32 : 0_u32)
    frame
  end

  # Scrolls *dy* wheel clicks down and *dx* right.
  def scroll(dy : Int32, dx : Int32) : Nil
    LibWl.wl_proxy_marshal_flags(@pointer, 5_u32, Pointer(LibWl::Interface).null, 1_u32, 0_u32, 0_u32)
    {% for axis in [{0, "dy"}, {1, "dx"}] %}
      unless {{axis[1].id}} == 0
        LibWl.wl_proxy_marshal_flags(@pointer, 7_u32, Pointer(LibWl::Interface).null, 1_u32, 0_u32,
          time, {{axis[0]}}_u32, {{axis[1].id}} * 15 * 256, {{axis[1].id}})
      end
    {% end %}
    frame
  end

  private def frame : Nil
    LibWl.wl_proxy_marshal_flags(@pointer, 4_u32, Pointer(LibWl::Interface).null, 1_u32, 0_u32)
    roundtrip
  end

  private def roundtrip : Nil
    raise Error.new("the Wayland connection broke") if LibWl.wl_display_roundtrip(@display) < 0
  end

  def close : Nil
    return if @display.null?
    LibWl.wl_proxy_marshal_flags(@keyboard, 3_u32, Pointer(LibWl::Interface).null, 1_u32,
      LibWl::MARSHAL_FLAG_DESTROY) unless @keyboard.null?
    LibWl.wl_proxy_marshal_flags(@pointer, 8_u32, Pointer(LibWl::Interface).null, 1_u32,
      LibWl::MARSHAL_FLAG_DESTROY) unless @pointer.null?
    LibWl.wl_display_flush(@display)
    LibWl.wl_display_disconnect(@display)
    @display = Pointer(Void).null
    Keymap::Xkb.state_unref(@xkb_state) unless @xkb_state.null?
    Keymap::Xkb.keymap_unref(@xkb_keymap) unless @xkb_keymap.null?
    Keymap::Xkb.context_unref(@xkb_context) unless @xkb_context.null?
  end
end
