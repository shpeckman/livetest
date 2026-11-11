require "file_utils"
require "./abort"
require "./app"
require "./case"
require "./subject"
require "./input"
require "./backends/kde"
require "./backends/sway"
require "./backends/offscreen"

# :nodoc:
# Runs cases on a backend: launches the app per case, places its window,
# replays the steps and compares screenshots with the goldens.
class Livetest::Runner
  class Failure < Exception
  end

  record Result, test : Case, passed : Bool, message : String?, elapsed : Time::Span

  # Options of a run.
  record Options, binary : String, out_dir : String, update : Bool, fail_fast : Bool, verbose : Bool

  # Errors of the steps that fail the case instead of the run.
  private alias StepError = Backend::Error | KWin::Error | Input::Error | Screenshot::Error | Image::Error |
                            DBus::Error | Keymap::Error | UInput::Error | Wayland::Error | App::Error

  @input : Input
  @abort : Abort? = nil
  @app : App? = nil
  @count = 0

  def initialize(@options : Options, @backend : Backend, @subject : Subject)
    @input = Input.new(@backend)
    if @backend.grabs_input?
      abort = Abort.new { abort_run("aborted by Escape") }
      abort.start
      @abort = abort
    end
    {Signal::INT, Signal::TERM, Signal::HUP}.each do |sig|
      sig.trap { abort_run("interrupted by #{sig}") }
    end
  end

  # Stops the abort watcher and closes the backend.
  def close : Nil
    @abort.try(&.stop)
    @backend.close
  end

  private def abort_run(why : String) : Nil
    @input.release_all rescue nil
    @app.try { |a| a.stop rescue nil }
    @backend.close rescue nil
    STDERR.puts "\n#{why}"
    exit 130
  end

  # Runs *test* and returns its result.
  def run(test : Case) : Result
    started = Time.instant
    dir = File.expand_path(File.join(@options.out_dir, test.name))
    @subject.cleanup(dir)
    FileUtils.rm_rf(dir)
    Dir.mkdir_p(dir)
    @count += 1
    app_id = "livetest-#{Process.pid}-#{@count}"
    deadline = Time.instant + test.timeout
    app = nil
    begin
      program, args = @backend.command(@options.binary, @subject.arguments(test, app_id))
      env = @backend.env(app_id, dir).merge(@subject.env(test, dir))
      app = App.new(program, args, env, app_id, dir, File.join(dir, "#{@subject.name}.log"))
      @app = app
      @backend.open(app, test, left(deadline))
      settle(deadline)
      test.steps.each do |step|
        raise Failure.new("line #{step.line}: case timed out after #{test.timeout.total_seconds}s") if Time.instant >= deadline
        begin
          perform(step, test, app, dir, deadline)
        rescue ex : Failure
          raise ex
        rescue ex : StepError
          raise Failure.new("line #{step.line}: #{ex.message}")
        end
      end
      Result.new(test, true, nil, Time.instant - started)
    rescue ex : Failure | StepError
      Result.new(test, false, ex.message.to_s, Time.instant - started)
    ensure
      @input.release_all
      if app
        @backend.finish(app) rescue nil
        app.wait(1.second) unless app.exited?
        app.stop
      end
      @subject.cleanup(dir) rescue nil
      @app = nil
    end
  end

  private def left(deadline : Time::Instant) : Time::Span
    Math.max(deadline - Time.instant, Time::Span.zero)
  end

  private def perform(step : Case::Step, test : Case, app : App, dir : String, deadline : Time::Instant) : Nil
    at = "line #{step.line}"
    case step
    in Case::Steps::Expect
      unless app.expect(step.text, left(deadline))
        raise Failure.new("#{at}: no line #{step.text.inspect} from the fifo")
      end
    in Case::Steps::Type
      @backend.focus
      @input.type(step.text)
    in Case::Steps::Key
      @backend.focus
      step.combos.each { |c| @input.combo(c) }
    in Case::Steps::Hold
      @backend.focus
      @input.key(step.key, step.down)
    in Case::Steps::Move
      @input.move(step.x, step.y)
    in Case::Steps::Click
      @input.click(Input.button(step.button), step.count)
    in Case::Steps::Button
      b = Input.button(step.button)
      step.down ? @input.button_down(b) : @input.button_up(b)
    in Case::Steps::Drag
      @input.drag({step.x1, step.y1}, {step.x2, step.y2}, Input.button(step.button))
    in Case::Steps::Scroll
      @input.scroll(step.dy, step.dx)
    in Case::Steps::Sleep
      sleep step.time
    in Case::Steps::Settle
      settle(deadline)
    in Case::Steps::Shoot
      shoot(step, test, dir, deadline)
    in Case::Steps::Clipboard
      clipboard(step, deadline)
    in Case::Steps::Copy
      @backend.copy(step.text)
    in Case::Steps::Resize
      @backend.resize(step.width, step.height)
      settle(deadline)
    in Case::Steps::Title
      title(step.text, deadline) || raise Failure.new("#{at}: title is #{@backend.title.inspect}, expected #{step.text.inspect}")
    in Case::Steps::Close
      @backend.close_window
      app.wait(left(deadline)) || raise Failure.new("#{at}: #{@subject.name} did not exit after close")
    in Case::Steps::Exit
      status = app.wait(left(deadline)) || raise Failure.new("#{at}: #{@subject.name} did not exit")
      if (code = step.code) && status.exit_code? != code
        raise Failure.new("#{at}: exit status #{status.exit_code? || status}, expected #{code}")
      end
    end
  end

  # Captures until two frames in a row are equal; returns the last one.
  private def settle(deadline : Time::Instant) : Image
    last = @backend.shot
    loop do
      sleep 60.milliseconds
      now = @backend.shot
      return now if now == last
      raise Failure.new("the window does not stop changing") if Time.instant >= deadline
      last = now
    end
  end

  private def shoot(step : Case::Steps::Shoot, test : Case, dir : String, deadline : Time::Instant) : Nil
    actual = settle(deadline)
    golden = File.join(test.goldens, "#{step.name}.png")
    actual_path = File.join(dir, "#{step.name}.png")
    if @options.update
      Dir.mkdir_p(File.dirname(golden))
      actual.write(golden)
      return
    end
    actual.write(actual_path)
    unless File.exists?(golden)
      raise Failure.new("line #{step.line}: no golden #{golden} (run with -u to accept #{actual_path})")
    end
    result = actual.compare(Image.read(golden), step.tolerance, step.masks)
    return if result.differing <= step.pixels
    diff_path = File.join(dir, "#{step.name}.diff.png")
    result.diff.try(&.write(diff_path))
    detail = result.diff ? "#{result.differing} of #{result.total} pixels differ, see #{diff_path}" : "size differs from the golden"
    raise Failure.new("line #{step.line}: shot #{step.name}: #{detail}")
  end

  private def clipboard(step : Case::Steps::Clipboard, deadline : Time::Instant) : Nil
    stop = Math.min(deadline, Time.instant + 3.seconds)
    loop do
      last = @backend.clipboard
      return if last == step.text
      if Time.instant >= stop
        raise Failure.new("line #{step.line}: clipboard is #{last.inspect}, expected #{step.text.inspect}")
      end
      sleep 100.milliseconds
    end
  end

  private def title(text : String, deadline : Time::Instant) : Bool
    stop = Math.min(deadline, Time.instant + 3.seconds)
    loop do
      return true if @backend.title == text
      return false if Time.instant >= stop
      sleep 100.milliseconds
    end
  end
end
