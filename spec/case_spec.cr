require "./spec_helper"

private alias Steps = Livetest::Case::Steps

private def parse_all(text : String) : Array(Livetest::Case)
  subject = TestTerminal.new
  Livetest::Case.parse(text, "/cases/cases.yml", subject.keys + ["set"]).tap &.each { |c| subject.check(c) }
end

# Parses *keys*, the indented keys of one case named demo.
private def parse(keys : String) : Livetest::Case
  parse_all("demo:\n#{keys}").first
end

private def options(keys : String) : Livetest::Terminal::Options
  TestTerminal.new.options(parse(keys))
end

private def error_of(text : String) : String
  expect_raises(Livetest::Case::Error) { parse_all(text) }.message.to_s
end

describe Livetest::Case do
  it "reads the keys and uses defaults for the rest" do
    c = parse(<<-YAML)
      # comment
      size: 40x8
      set:
        - terminal.scrollback=10
        - 'links.opener=sh -c ''echo: $0'''
      run: echo hi
      steps:
        - settle
    YAML
    {c.name, c.x, c.y, c.timeout}.should eq({"demo", 100, 100, 30.seconds})
    c.path.should eq("/cases/cases.yml")
    c.goldens.should eq("/cases/goldens/demo")
    c.steps.should eq([Steps::Settle.new(9)] of Livetest::Case::Step)
    c.modes.should be_empty
    set = c.field?("set").should_not be_nil
    set.items.should eq([Livetest::Case::Item.new("terminal.scrollback=10", 5),
                         Livetest::Case::Item.new("links.opener=sh -c 'echo: $0'", 6)])
    set.error("bad", set.items[1]).message.should eq("/cases/cases.yml:6: bad")
    c.field?("font").should be_nil
    c.resolve("fonts/x.ttf").should eq("/cases/fonts/x.ttf")
  end

  it "reads the terminal options with their defaults" do
    options("  size: 40x8\n  run: echo hi\n").should eq(Livetest::Terminal::Options.new(40, 8, "/cases/fonts/Default.ttf", "echo hi"))
    options("  steps: []\n").should eq(Livetest::Terminal::Options.new(80, 24, "/cases/fonts/Default.ttf", "exec sleep infinity"))
  end

  it "reads a multi-line run" do
    options("  run: |\n    echo a\n    echo b\n").command.should eq("echo a\necho b\n")
  end

  it "resolves font files against the cases file" do
    options("  font: Iosevka:style=Medium\n").font.should eq("Iosevka:style=Medium")
    options("  font: fonts/Other.ttf\n").font.should eq("/cases/fonts/Other.ttf")
    options("  font: /usr/share/fonts/x.ttf\n").font.should eq("/usr/share/fonts/x.ttf")
    options("  font: ~/x.ttf\n").font.should eq("~/x.ttf")
  end

  it "reads the modes a case runs in, as a list or a string" do
    parse("  modes: [kde, sway]\n").modes.should eq(["kde", "sway"])
    parse("  modes: offscreen\n").modes.should eq(["offscreen"])
    error_of("demo:\n  modes: []\n").should contain("modes wants MODE...")
    error_of("demo:\n  modes: [wayland]\n").should contain("unknown mode wayland")
  end

  it "keeps the cases in the file's order" do
    parse_all("b:\n  size: 10x2\na: {}\nc: {}\n").map(&.name).should eq(["b", "a", "c"])
    parse_all("").should be_empty
    parse_all("# only a comment\n").should be_empty
  end

  it "parses every step with its line in the file" do
    c = parse(<<-YAML)
      steps:
        - expect done
        - type a\\tb\\n
        - key ctrl+shift+c Return
        - press Shift_L
        - release Shift_L
        - move 10 20
        - click right 2
        - click 3
        - down middle
        - up
        - drag 1 2 3 4
        - scroll -3 1
        - sleep 50
        - settle
        - shoot out tolerance=4 pixels=10 mask=0,0,5,6
        - clipboard x y
        - copy z
        - resize 300 200
        - title hello
        - close
        - exit 3
        - 'type a: b #c'
    YAML
    c.steps.should eq([
      Steps::Expect.new(3, "done"),
      Steps::Type.new(4, "a\tb\n"),
      Steps::Key.new(5, ["ctrl+shift+c", "Return"]),
      Steps::Hold.new(6, "Shift_L", true),
      Steps::Hold.new(7, "Shift_L", false),
      Steps::Move.new(8, 10, 20),
      Steps::Click.new(9, "right", 2),
      Steps::Click.new(10, "left", 3),
      Steps::Button.new(11, "middle", true),
      Steps::Button.new(12, "left", false),
      Steps::Drag.new(13, 1, 2, 3, 4, "left"),
      Steps::Scroll.new(14, -3, 1),
      Steps::Sleep.new(15, 50.milliseconds),
      Steps::Settle.new(16),
      Steps::Shoot.new(17, "out", 4, 10, [Livetest::Rect.new(0, 0, 5, 6)]),
      Steps::Clipboard.new(18, "x y"),
      Steps::Copy.new(19, "z"),
      Steps::Resize.new(20, 300, 200),
      Steps::Title.new(21, "hello"),
      Steps::Close.new(22),
      Steps::Exit.new(23, 3),
      Steps::Type.new(24, "a: b #c"),
    ] of Livetest::Case::Step)
  end

  it "rejects bad files, names and keys with their line" do
    error_of("- a\n").should eq("/cases/cases.yml:1: a cases file maps case names to cases")
    error_of("a:\n  size: [1\n").should start_with("/cases/cases.yml: ")
    error_of("a:\n  size: 10x2\na:\n").should eq("/cases/cases.yml:3: duplicate case a")
    error_of("a/b:\n").should eq("/cases/cases.yml:1: bad case name a/b")
    error_of("a: x\n").should eq("/cases/cases.yml:1: case a wants a mapping")
    error_of("a:\n  size: 10x2\n  size: 20x2\n").should eq("/cases/cases.yml:3: duplicate key size")
    error_of("a:\n  header: x\n").should eq("/cases/cases.yml:2: unknown key header")
    error_of("a:\n  steps: {x: 1}\n").should eq("/cases/cases.yml:2: steps wants a string or a list")
  end

  it "rejects bad steps and arguments with their line" do
    error_of("a:\n  steps:\n    - settle\n    - jump\n").should eq("/cases/cases.yml:4: unknown command jump")
    error_of("a:\n  steps:\n    - size 10x10\n").should eq("/cases/cases.yml:3: unknown command size")
    error_of("a:\n  steps:\n    - type a: b\n").should contain(":3: not a string; quote text")
    error_of("a:\n  size: 10\n").should eq("/cases/cases.yml:2: size wants COLSxROWS")
    error_of("a:\n  steps: [click wheel 2]\n").should contain("click wants")
    error_of("a:\n  steps: [move 1 x]\n").should contain("x is not a number")
    error_of("a:\n  steps: [shoot ../x]\n").should contain("bad shot name")
    error_of("a:\n  steps:\n    - shoot x mask=1,2\n").should contain("mask wants X,Y,W,H")
    error_of("a:\n  run: ''\n").should eq("/cases/cases.yml:2: run wants COMMAND")
  end

  it "unescapes text" do
    Livetest::Case.unescape("a\\nb\\e\\x41\\u{20AC}\\s\\\\").should eq("a\nb\eA€ \\")
  end
end
