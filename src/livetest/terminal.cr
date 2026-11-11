require "./subject"

# A `Subject` for terminal emulators: cases take the keys `size`, `font`
# and `run`, and the shell in the terminal is the same on every machine.
abstract class Livetest::Terminal < Livetest::Subject
  # The terminal setup of a case: the grid size in cells, the font (nil
  # for the terminal's own) and the shell *command* to run in it.
  record Options, cols : Int32, rows : Int32, font : String?, command : String

  # Returns the command-line arguments that start the terminal with
  # *options* and the window class *app_id*.
  abstract def arguments(options : Options, app_id : String) : Array(String)

  # Returns the font of cases without a `font` key, nil for the
  # terminal's own.
  def default_font(test : Case) : String?
    nil
  end

  def keys : Array(String)
    ["size", "font", "run"]
  end

  def check(test : Case) : Nil
    options(test)
  end

  def arguments(test : Case, app_id : String) : Array(String)
    arguments(options(test), app_id)
  end

  # Returns `/bin/sh` as the shell with the prompt `$ ` and its history in
  # *dir*, so screenshots match on every machine.
  def env(test : Case, dir : String) : Hash(String, String?)
    {
      "SHELL"    => "/bin/sh",
      "PS1"      => "$ ",
      "ENV"      => nil,
      "HISTFILE" => File.join(dir, "history"),
    } of String => String?
  end

  # Returns the terminal setup of *test*.
  #
  # Raises `Case::Error` for a bad `size`, `font` or `run`.
  def options(test : Case) : Options
    cols, rows = 80, 24
    if field = test.field?("size")
      c, sep, r = field.text.partition('x')
      c, r = c.to_i?, r.to_i?
      raise field.error("size wants COLSxROWS") unless !sep.empty? && c && r && c > 0 && r > 0
      cols, rows = c, r
    end
    font = test.field?("font").try do |field|
      name = field.text
      raise field.error("font wants NAME") if name.empty?
      font_path(test, name)
    end
    command = test.field?("run").try do |field|
      field.text.presence || raise field.error("run wants COMMAND")
    end
    Options.new(cols, rows, font || default_font(test), command || "exec sleep infinity")
  end

  # Returns *name* made absolute against the cases file when it is a path
  # with `/` not starting with `~`; a font name otherwise.
  private def font_path(test : Case, name : String) : String
    name.includes?('/') && !name.starts_with?('~') ? test.resolve(name) : name
  end
end
