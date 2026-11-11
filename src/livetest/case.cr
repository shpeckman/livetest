require "yaml"
require "./image"

# One test case of a cases file: where its window goes, its time limit,
# the modes it runs in, its steps and the keys the `Subject` declared.
class Livetest::Case
  # Raised for a cases file that cannot be read or parsed.
  class Error < Exception
  end

  # One value of a `Field`, at *line* of the cases file.
  record Item, text : String, line : Int32

  # The value of a key a `Subject` declared: a string or a list of them.
  record Field, key : String, items : Array(Item), path : String, line : Int32 do
    # Returns the items joined by spaces.
    def text : String
      items.join(' ', &.text)
    end

    # Returns an `Error` with *message*, prefixed with the location of
    # *item*, or of the key when *item* is nil.
    def error(message : String, item : Item? = nil) : Error
      Error.new("#{path}:#{item.try(&.line) || line}: #{message}")
    end
  end

  # :nodoc:
  module Steps
    record Expect, line : Int32, text : String
    record Type, line : Int32, text : String
    record Key, line : Int32, combos : Array(String)
    record Hold, line : Int32, key : String, down : Bool
    record Move, line : Int32, x : Int32, y : Int32
    record Click, line : Int32, button : String, count : Int32
    record Button, line : Int32, button : String, down : Bool
    record Drag, line : Int32, x1 : Int32, y1 : Int32, x2 : Int32, y2 : Int32, button : String
    record Scroll, line : Int32, dy : Int32, dx : Int32
    record Sleep, line : Int32, time : Time::Span
    record Settle, line : Int32
    record Shoot, line : Int32, name : String, tolerance : Int32, pixels : Int32, masks : Array(Rect)
    record Clipboard, line : Int32, text : String
    record Copy, line : Int32, text : String
    record Resize, line : Int32, width : Int32, height : Int32
    record Title, line : Int32, text : String
    record Close, line : Int32
    record Exit, line : Int32, code : Int32?
  end

  # :nodoc:
  alias Step = Steps::Expect | Steps::Type | Steps::Key | Steps::Hold | Steps::Move | Steps::Click |
               Steps::Button | Steps::Drag | Steps::Scroll | Steps::Sleep | Steps::Settle | Steps::Shoot |
               Steps::Clipboard | Steps::Copy | Steps::Resize | Steps::Title | Steps::Close | Steps::Exit

  # :nodoc:
  # The modes a case can run in.
  MODES = {"kde", "sway", "offscreen"}

  private BUTTONS = {"left", "middle", "right"}
  # The keys every case takes besides `steps` and the subject's keys.
  private HEADERS = {"at", "timeout", "modes"}
  private alias Node = YAML::Nodes::Node

  getter name : String
  # Returns the path of the cases file.
  getter path : String
  # :nodoc:
  getter x : Int32 = 100
  # :nodoc:
  getter y : Int32 = 100
  getter timeout : Time::Span = 30.seconds
  # Returns the modes the case runs in; empty for every mode.
  getter modes = [] of String
  # :nodoc:
  getter steps = [] of Step
  @fields = {} of String => Field

  # :nodoc:
  def initialize(@path : String, @name : String, @keys : Array(String))
  end

  # Returns the field of the declared *key*, nil when the case lacks it.
  def field?(key : String) : Field?
    @fields[key]?
  end

  # Returns *path* made absolute against the cases file's directory.
  def resolve(path : String) : String
    File.expand_path(path, File.dirname(@path), home: true)
  end

  # :nodoc:
  # Returns the directory holding the golden screenshots of this case.
  def goldens : String
    File.join(File.dirname(@path), "goldens", @name)
  end

  # :nodoc:
  # Returns the cases of the cases file *path*, in the file's order; a case
  # takes the keys *keys* besides the built-in ones.
  def self.read(path : String, keys : Array(String) = [] of String) : Array(Case)
    parse(File.read(path), path, keys)
  rescue ex : File::Error
    raise Error.new("#{path}: #{ex.message}")
  end

  # :nodoc:
  # Returns the cases of *text*, a cases file read from *path*.
  def self.parse(text : String, path : String, keys : Array(String) = [] of String) : Array(Case)
    root = begin
      YAML::Nodes.parse(text).nodes.first?
    rescue ex : YAML::ParseException
      raise Error.new("#{path}: #{ex.message}")
    end
    cases = [] of Case
    return cases if root.nil? || empty?(root)
    unless root.is_a?(YAML::Nodes::Mapping)
      raise Error.new("#{path}:#{root.start_line}: a cases file maps case names to cases")
    end
    names = Set(String).new
    root.each do |key, value|
      name = located(path, key) do
        n = text(key)
        raise Error.new("bad case name #{n}") unless n.matches?(/\A[\w.-]+\z/)
        raise Error.new("duplicate case #{n}") unless names.add?(n)
        raise Error.new("case #{n} wants a mapping") unless value.is_a?(YAML::Nodes::Mapping)
        n
      end
      c = new(path, name, keys)
      c.load(value.as(YAML::Nodes::Mapping))
      cases << c
    end
    cases
  end

  protected def load(mapping : YAML::Nodes::Mapping) : Nil
    keys = Set(String).new
    mapping.each do |key, value|
      field = Case.located(@path, key) do
        k = Case.text(key)
        raise Error.new("unknown key #{k}") unless k == "steps" || HEADERS.includes?(k) || @keys.includes?(k)
        raise Error.new("duplicate key #{k}") unless keys.add?(k)
        k
      end
      items = Case.located(@path, value) { Case.items(value, field) }
      case field
      when "steps"
        items.each { |item| Case.located(@path, item) { @steps << step(Case.text(item), item.start_line) } }
      when .in?(HEADERS)
        Case.located(@path, value) do
          rest = items.map { |item| Case.text(item) }.join(' ')
          header_line(field, rest.split)
        end
      else
        texts = items.map { |item| Case.located(@path, item) { Item.new(Case.text(item), item.start_line) } }
        @fields[field] = Field.new(field, texts, @path, value.start_line)
      end
    end
  end

  # Runs the block; prefixes the message of an `Error` it raises with
  # *path* and the line of *node*.
  protected def self.located(path : String, node : Node, &)
    yield
  rescue ex : Error | ArgumentError
    raise Error.new("#{path}:#{node.start_line}: #{ex.message}")
  end

  # The items of *node*, the value of the key *field*: the node itself
  # when it is a string, none when it is empty.
  protected def self.items(node : Node, field : String) : Array(Node)
    case node
    when YAML::Nodes::Sequence then node.nodes
    when YAML::Nodes::Scalar   then empty?(node) ? [] of Node : [node] of Node
    else                            raise Error.new("#{field} wants a string or a list")
    end
  end

  protected def self.text(node : Node) : String
    return node.value if node.is_a?(YAML::Nodes::Scalar)
    raise Error.new("not a string; quote text that holds \": \" or \" #\"")
  end

  private def self.empty?(node : Node) : Bool
    node.is_a?(YAML::Nodes::Scalar) && node.value.empty? && node.style.plain?
  end

  private def header_line(command : String, args : Array(String)) : Nil
    case command
    when "timeout" then @timeout = positive(expect_args(args, 1, "timeout SECONDS")[0]).seconds
    when "modes"
      raise Error.new("modes wants MODE...") if args.empty?
      args.each { |m| raise Error.new("unknown mode #{m}") unless MODES.includes?(m) }
      @modes = args
    when "at"
      a = expect_args(args, 2, "at X Y")
      @x = int(a[0])
      @y = int(a[1])
    end
  end

  private def step(text : String, line : Int32) : Step
    command, _, rest = text.strip.partition(/\s+/)
    step(command, rest, rest.split, line)
  end

  private def step(command : String, rest : String, args : Array(String), line : Int32) : Step
    case command
    when "expect"  then Steps::Expect.new(line, Case.unescape(need(rest, "expect TEXT")))
    when "type"    then Steps::Type.new(line, Case.unescape(need(rest, "type TEXT")))
    when "key"     then Steps::Key.new(line, args.empty? ? raise(Error.new("key wants COMBO...")) : args)
    when "press"   then Steps::Hold.new(line, expect_args(args, 1, "press KEY")[0], true)
    when "release" then Steps::Hold.new(line, expect_args(args, 1, "release KEY")[0], false)
    when "move"
      a = expect_args(args, 2, "move X Y")
      Steps::Move.new(line, int(a[0]), int(a[1]))
    when "click"
      raise Error.new("click wants [BUTTON] [COUNT]") if args.size > 2
      button = args.first?.try { |b| BUTTONS.includes?(b) ? b : nil }
      raise Error.new("click wants [BUTTON] [COUNT]") if args.size == 2 && button.nil?
      count = (button ? args[1]? : args[0]?).try { |n| positive(n) } || 1
      Steps::Click.new(line, button || "left", count)
    when "down", "up"
      raise Error.new("#{command} wants [BUTTON]") if args.size > 1
      Steps::Button.new(line, button(args[0]? || "left"), command == "down")
    when "drag"
      raise Error.new("drag wants X1 Y1 X2 Y2 [BUTTON]") unless args.size.in?(4, 5)
      Steps::Drag.new(line, int(args[0]), int(args[1]), int(args[2]), int(args[3]), button(args[4]? || "left"))
    when "scroll"
      raise Error.new("scroll wants DY [DX]") unless args.size.in?(1, 2)
      Steps::Scroll.new(line, int(args[0]), int(args[1]? || "0"))
    when "sleep"     then Steps::Sleep.new(line, int(expect_args(args, 1, "sleep MS")[0]).milliseconds)
    when "settle"    then Steps::Settle.new(line)
    when "shoot"     then shoot(args, line)
    when "clipboard" then Steps::Clipboard.new(line, Case.unescape(rest))
    when "copy"      then Steps::Copy.new(line, Case.unescape(rest))
    when "resize"
      a = expect_args(args, 2, "resize WIDTH HEIGHT")
      Steps::Resize.new(line, positive(a[0]), positive(a[1]))
    when "title" then Steps::Title.new(line, Case.unescape(rest))
    when "close" then Steps::Close.new(line)
    when "exit"
      raise Error.new("exit wants [CODE]") if args.size > 1
      Steps::Exit.new(line, args[0]?.try { |a| int(a) })
    else
      raise Error.new("unknown command #{command}")
    end
  end

  private def shoot(args : Array(String), line : Int32) : Step
    name = args.first? || raise Error.new("shoot wants NAME [tolerance=N] [pixels=N] [mask=X,Y,W,H]...")
    raise Error.new("bad shot name #{name}") unless name.matches?(/\A[\w.-]+\z/)
    tolerance = 0
    pixels = 0
    masks = [] of Rect
    args[1..].each do |opt|
      key, sep, value = opt.partition('=')
      raise Error.new("bad shoot option #{opt}") if sep.empty?
      case key
      when "tolerance" then tolerance = int(value)
      when "pixels"    then pixels = int(value)
      when "mask"
        n = value.split(',').map { |v| int(v) }
        raise Error.new("mask wants X,Y,W,H") unless n.size == 4
        masks << Rect.new(n[0], n[1], n[2], n[3])
      else
        raise Error.new("unknown shoot option #{key}")
      end
    end
    Steps::Shoot.new(line, name, tolerance, pixels, masks)
  end

  private def button(name : String) : String
    BUTTONS.includes?(name) ? name : raise Error.new("unknown button #{name}")
  end

  private def need(rest : String, usage : String) : String
    rest.empty? ? raise(Error.new("#{usage.split.first} wants #{usage.partition(' ')[2]}")) : rest
  end

  private def expect_args(args : Array(String), n : Int32, usage : String) : Array(String)
    raise Error.new("#{usage.split.first} wants #{usage.partition(' ')[2]}") unless args.size == n
    args
  end

  private def int(s : String) : Int32
    s.to_i32? || raise Error.new("#{s} is not a number")
  end

  private def positive(s : String) : Int32
    v = int(s)
    raise Error.new("#{s} is not positive") unless v > 0
    v
  end

  # :nodoc:
  # Decodes `\n \r \t \e \s \\ \xHH \u{H...}` in *text*.
  def self.unescape(text : String) : String
    text.gsub(/\\(x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]{1,6}\}|.)/) do |_, m|
      e = m[1]
      case e[0]
      when 'n'  then "\n"
      when 'r'  then "\r"
      when 't'  then "\t"
      when 'e'  then "\e"
      when 's'  then " "
      when '\\' then "\\"
      when 'x'  then e[1..].to_i(16).chr.to_s
      when 'u'
        raise Error.new("\\u wants {HEX}") if e.size == 1
        n = e[2..-2].to_i(16)
        raise Error.new("bad escape \\#{e}") if n > 0x10FFFF || 0xD800 <= n <= 0xDFFF
        n.chr.to_s
      else
        raise Error.new("unknown escape \\#{e}")
      end
    end
  end
end
