require "./case"

# The app a harness tests: how to start it for a `Case` and which keys
# its cases take besides the built-in ones.
#
# The app must take *app_id* as its window class (Wayland app id), so the
# harness finds its window. Subclass `Terminal` instead for a terminal
# emulator.
#
# ```
# class MyApp < Livetest::Subject
#   def name : String
#     "myapp"
#   end
#
#   def arguments(test : Livetest::Case, app_id : String) : Array(String)
#     ["--class", app_id]
#   end
# end
#
# exit Livetest.run(ARGV, MyApp.new)
# ```
abstract class Livetest::Subject
  # Returns the app's name, used in messages and to name its log file.
  abstract def name : String

  # Returns the command-line arguments that start the app for *test* with
  # the window class *app_id*.
  abstract def arguments(test : Case, app_id : String) : Array(String)

  # Returns the executable to test unless the command line names one.
  def binary : String
    name
  end

  # Returns the keys a case may hold besides the built-in ones.
  def keys : Array(String)
    [] of String
  end

  # Validates the declared keys of *test* when the cases file is read.
  #
  # Raises `Case::Error`, preferably from `Case::Field#error`, for a bad
  # value.
  def check(test : Case) : Nil
  end

  # Returns the environment to add for the app of *test*, which runs in
  # *dir*; nil values unset a variable.
  def env(test : Case, dir : String) : Hash(String, String?)
    {} of String => String?
  end

  # Returns the path of the worker executable for mode offscreen, nil
  # when the app has none.
  #
  # The worker takes the same arguments as the app, runs the app's window
  # code without a compositor and serves the harness through a
  # `Worker`.
  def worker : String?
    nil
  end

  # Ends what the app left running in *dir*, before a case starts there
  # and after it ended.
  def cleanup(dir : String) : Nil
  end
end
