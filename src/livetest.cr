require "./livetest/cli"
require "./livetest/terminal"

# Live-tests a GUI app: starts it per test case on KDE Plasma, in a
# nested sway or offscreen, replays input and compares window screenshots
# with goldens. The cases file format is in README.md.
#
# ```
# require "livetest"
#
# exit Livetest.run(ARGV, MyApp.new)
# ```
module Livetest
  VERSION = "0.1.0"

  # Runs the command line *args* against *subject*; returns the exit
  # status.
  def self.run(args : Array(String), subject : Subject) : Int32
    CLI.run(args, subject)
  end
end
