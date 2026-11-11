require "spec"
require "../src/livetest"
require "../src/livetest/worker"

class TestTerminal < Livetest::Terminal
  def name : String
    "term"
  end

  def arguments(options : Options, app_id : String) : Array(String)
    ["-g", "#{options.cols}x#{options.rows}", "-c", app_id, "-e", "sh", "-c", options.command]
  end

  def default_font(test : Livetest::Case) : String?
    test.resolve("fonts/Default.ttf")
  end
end
