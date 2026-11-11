# :nodoc:
# Virtual input devices through `/dev/uinput`: a keyboard sending evdev key
# codes and an absolute pointer with buttons and wheels. The compositor
# treats their events like those of real hardware.
module Livetest::UInput
  class Error < Exception
  end

  NAME_PREFIX = "livetest"

  EV_SYN = 0x00_u16
  EV_KEY = 0x01_u16
  EV_REL = 0x02_u16
  EV_ABS = 0x03_u16

  REL_HWHEEL        = 0x06_u16
  REL_WHEEL         = 0x08_u16
  REL_WHEEL_HI_RES  = 0x0B_u16
  REL_HWHEEL_HI_RES = 0x0C_u16

  ABS_X = 0x00_u16
  ABS_Y = 0x01_u16

  BTN_LEFT   = 0x110_u16
  BTN_RIGHT  = 0x111_u16
  BTN_MIDDLE = 0x112_u16

  ABS_MAX = 32767

  private UI_DEV_CREATE  =     0x5501_u64
  private UI_DEV_DESTROY =     0x5502_u64
  private UI_DEV_SETUP   = 0x405C5503_u64
  private UI_ABS_SETUP   = 0x401C5504_u64
  private UI_SET_EVBIT   = 0x40045564_u64
  private UI_SET_KEYBIT  = 0x40045565_u64
  private UI_SET_RELBIT  = 0x40045566_u64
  private UI_SET_ABSBIT  = 0x40045567_u64

  private BUS_VIRTUAL = 0x06_u16

  lib C
    struct InputId
      bustype : UInt16
      vendor : UInt16
      product : UInt16
      version : UInt16
    end

    struct Setup
      id : InputId
      name : UInt8[80]
      ff_effects_max : UInt32
    end

    struct AbsInfo
      value : Int32
      minimum : Int32
      maximum : Int32
      fuzz : Int32
      flat : Int32
      resolution : Int32
    end

    struct AbsSetup
      code : UInt16
      absinfo : AbsInfo
    end

    struct InputEvent
      sec : LibC::Long
      usec : LibC::Long
      type : UInt16
      code : UInt16
      value : Int32
    end

    fun ioctl(fd : LibC::Int, request : LibC::ULong, ...) : LibC::Int
  end

  # One uinput device; destroyed by `#close`.
  abstract class Device
    @fd : Int32

    def initialize(name : String, product : UInt16)
      @fd = LibC.open("/dev/uinput", LibC::O_WRONLY | LibC::O_CLOEXEC)
      raise Error.new("cannot open /dev/uinput: #{Errno.value.message} (add yourself to the input group)") if @fd < 0
      configure
      setup = C::Setup.new
      setup.id = C::InputId.new(bustype: BUS_VIRTUAL, vendor: 0x1209_u16, product: product, version: 1_u16)
      full = "#{NAME_PREFIX} #{name}".to_slice
      full[0, Math.min(full.size, 79)].each_with_index { |b, i| setup.name[i] = b }
      check C.ioctl(@fd, UI_DEV_SETUP, pointerof(setup)), "UI_DEV_SETUP"
      check C.ioctl(@fd, UI_DEV_CREATE), "UI_DEV_CREATE"
    end

    private abstract def configure : Nil

    private def check(result : Int32, what : String) : Nil
      raise Error.new("uinput #{what}: #{Errno.value.message}") if result < 0
    end

    private def enable(request : UInt64, code : Int) : Nil
      check C.ioctl(@fd, request, code.to_i32), "enable #{code}"
    end

    private def set_ev(type : UInt16) : Nil
      enable(UI_SET_EVBIT, type)
    end

    private def set_key(code : Int) : Nil
      enable(UI_SET_KEYBIT, code)
    end

    private def set_rel(code : UInt16) : Nil
      enable(UI_SET_RELBIT, code)
    end

    private def set_abs(code : UInt16, max : Int32) : Nil
      enable(UI_SET_ABSBIT, code)
      setup = C::AbsSetup.new(code: code, absinfo: C::AbsInfo.new(minimum: 0, maximum: max))
      check C.ioctl(@fd, UI_ABS_SETUP, pointerof(setup)), "UI_ABS_SETUP"
    end

    protected def emit(type : UInt16, code : UInt16, value : Int32) : Nil
      event = C::InputEvent.new(type: type, code: code, value: value)
      written = LibC.write(@fd, pointerof(event).as(Void*), sizeof(C::InputEvent))
      raise Error.new("uinput write: #{Errno.value.message}") unless written == sizeof(C::InputEvent)
    end

    protected def sync : Nil
      emit(EV_SYN, 0_u16, 0)
    end

    def close : Nil
      return if @fd < 0
      release_all
      C.ioctl(@fd, UI_DEV_DESTROY)
      LibC.close(@fd)
      @fd = -1
    end

    # Releases everything held down.
    abstract def release_all : Nil
  end

  # A keyboard with every key code below 256.
  class Keyboard < Device
    @down = Set(UInt16).new

    def initialize
      super("keyboard", 0x0001_u16)
    end

    private def configure : Nil
      set_ev(EV_KEY)
      (1..255).each { |code| set_key(code) }
    end

    def press(code : UInt16) : Nil
      emit(EV_KEY, code, 1)
      sync
      @down << code
    end

    def release(code : UInt16) : Nil
      emit(EV_KEY, code, 0)
      sync
      @down.delete(code)
    end

    def release_all : Nil
      @down.to_a.each { |code| release(code) }
    end
  end

  # An absolute pointer covering `0..ABS_MAX` on both axes, with three
  # buttons and both wheels.
  class Pointer < Device
    @down = Set(UInt16).new

    def initialize
      super("pointer", 0x0002_u16)
    end

    private def configure : Nil
      set_ev(EV_KEY)
      set_ev(EV_ABS)
      set_ev(EV_REL)
      {BTN_LEFT, BTN_RIGHT, BTN_MIDDLE}.each { |code| set_key(code) }
      set_abs(ABS_X, ABS_MAX)
      set_abs(ABS_Y, ABS_MAX)
      {REL_WHEEL, REL_HWHEEL, REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES}.each { |code| set_rel(code) }
    end

    # Moves to device coordinates *x*, *y* in `0..ABS_MAX`.
    def move(x : Int32, y : Int32) : Nil
      emit(EV_ABS, ABS_X, x.clamp(0, ABS_MAX))
      emit(EV_ABS, ABS_Y, y.clamp(0, ABS_MAX))
      sync
    end

    def press(button : UInt16) : Nil
      emit(EV_KEY, button, 1)
      sync
      @down << button
    end

    def release(button : UInt16) : Nil
      emit(EV_KEY, button, 0)
      sync
      @down.delete(button)
    end

    # Scrolls by notches: positive *dy* down, positive *dx* right.
    def scroll(dy : Int32, dx : Int32 = 0) : Nil
      unless dy == 0
        emit(EV_REL, REL_WHEEL, -dy)
        emit(EV_REL, REL_WHEEL_HI_RES, -dy * 120)
      end
      unless dx == 0
        emit(EV_REL, REL_HWHEEL, dx)
        emit(EV_REL, REL_HWHEEL_HI_RES, dx * 120)
      end
      sync
    end

    def release_all : Nil
      @down.to_a.each { |button| release(button) }
    end
  end
end
