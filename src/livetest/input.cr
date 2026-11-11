require "./backend"

# :nodoc:
# Keyboard and pointer actions of the steps, built from a backend's key and
# button events and its keymap. Keeps track of what is held down so a
# failure releases it.
class Livetest::Input
  class Error < Exception
  end

  # Pause between key and button events, so clients see them in order and
  # without coalescing.
  property delay : Time::Span = 8.milliseconds

  @held_keys = Set(UInt16).new
  @held_buttons = Set(UInt16).new

  def initialize(@backend : Backend)
  end

  def keymap : Keymap
    @backend.keymap
  end

  # Releases every key and button held down.
  def release_all : Nil
    @held_keys.each { |k| @backend.key(k, false) rescue nil }
    @held_buttons.each { |b| @backend.button(b, false) rescue nil }
    @held_keys.clear
    @held_buttons.clear
  end

  # Returns the evdev code of *button* (`left`, `middle`, `right`).
  def self.button(name : String) : UInt16
    case name
    when "left"   then Backend::BTN_LEFT
    when "middle" then Backend::BTN_MIDDLE
    when "right"  then Backend::BTN_RIGHT
    else               raise Error.new("unknown button #{name}")
    end
  end

  # Moves the pointer to *x*, *y* in the client area.
  def move(x : Int32, y : Int32) : Nil
    @backend.move(x, y)
    sleep @delay
  end

  def button_down(button : UInt16) : Nil
    @held_buttons << button
    @backend.button(button, true)
    sleep @delay
  end

  def button_up(button : UInt16) : Nil
    @held_buttons.delete(button)
    @backend.button(button, false)
    sleep @delay
  end

  def click(button : UInt16, count : Int32) : Nil
    count.times do
      button_down(button)
      button_up(button)
    end
  end

  # Presses *button* at *from*, moves to *to* in *steps* and releases it.
  def drag(from : {Int32, Int32}, to : {Int32, Int32}, button : UInt16, steps : Int32 = 12) : Nil
    move(*from)
    button_down(button)
    (1..steps).each do |i|
      move(from[0] + (to[0] - from[0]) * i // steps, from[1] + (to[1] - from[1]) * i // steps)
    end
    sleep 50.milliseconds
    button_up(button)
  end

  def scroll(dy : Int32, dx : Int32 = 0) : Nil
    @backend.scroll(dy, dx)
    sleep @delay
  end

  # Types *text* with the layout's keys; raises for characters it lacks.
  def type(text : String) : Nil
    strokes = text.chars.map do |c|
      keymap.char(c) || raise Error.new("layout #{keymap.description} cannot type #{c.inspect}")
    end
    strokes.each { |s| stroke(s.code, s.modifiers) }
  end

  # Presses a combination like `ctrl+shift+c`, `alt+F4` or `Return`: the
  # modifiers named before the last `+` and the keysym after it.
  def combo(combo : String) : Nil
    parts = combo.split('+')
    parts = parts[0..-3] + ["+"] if combo.ends_with?("++")
    name = parts.pop
    mods = parts.map { |m| keymap.modifier(m) || raise Error.new("unknown modifier #{m} in #{combo}") }
    stroke = (name.size == 1 ? keymap.char(name[0]) : nil) || keymap.named(name) ||
             raise Error.new("layout #{keymap.description} has no key #{name}")
    stroke(stroke.code, (mods + stroke.modifiers).uniq)
  end

  # Holds or releases the key of keysym *name* or modifier *name*.
  def key(name : String, down : Bool) : Nil
    code = keymap.modifier(name) || keymap.named(name).try(&.code) ||
           raise Error.new("layout #{keymap.description} has no key #{name}")
    down ? press(code) : release(code)
  end

  private def press(code : UInt16) : Nil
    @held_keys << code
    @backend.key(code, true)
    sleep @delay
  end

  private def release(code : UInt16) : Nil
    @held_keys.delete(code)
    @backend.key(code, false)
    sleep @delay
  end

  private def stroke(code : UInt16, modifiers : Array(UInt16)) : Nil
    modifiers.each { |m| press(m) }
    press(code)
    release(code)
    modifiers.reverse_each { |m| release(m) }
  end
end
