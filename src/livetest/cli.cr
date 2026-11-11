require "option_parser"
require "./runner"
require "./setup"

# :nodoc:
# The harness's command line.
module Livetest::CLI
  # Runs the command line *args* against *subject*; returns the exit
  # status.
  def self.run(args : Array(String), subject : Subject) : Int32
    if args.first? == "setup"
      exe = Process.executable_path || (STDERR.puts "cannot find the executable path"; return 1)
      puts "wrote #{Setup.install(exe)} for #{exe}"
      return 0
    end
    binary = subject.binary
    program = File.basename(PROGRAM_NAME)
    file = "cases.yml"
    out_dir = "out"
    update = false
    fail_fast = false
    verbose = false
    mode = "kde"
    show = false
    help = nil
    parser = OptionParser.new do |p|
      p.banner = <<-USAGE
        usage: #{program} [options] [CASE...]
               #{program} setup

        Runs the named cases of the cases file (default: all of them, in the
        file's order) against #{subject.name}. Mode kde uses the
        Plasma session and takes over the keyboard and the pointer (press
        Escape three times to abort); sway runs a nested sway; offscreen
        runs #{subject.name}'s window code without a compositor. `setup` lets this
        executable take window screenshots in mode kde.

        options:
        USAGE
      p.on("-b BINARY", "#{subject.name} executable (default: #{subject.binary})") { |v| binary = v }
      p.on("-c FILE", "cases file (default: cases.yml)") { |v| file = v }
      p.on("-m MODE", "kde, sway or offscreen (default: kde)") { |v| mode = v }
      p.on("-S", "show the nested sway as a window") { show = true }
      p.on("-o DIR", "output directory (default: out)") { |v| out_dir = v }
      p.on("-u", "write the screenshots as the new goldens") { update = true }
      p.on("-x", "stop at the first failure") { fail_fast = true }
      p.on("-v", "list the cases as they start") { verbose = true }
      p.on("-h", "--help", "show this help") { help = p.to_s }
      p.invalid_option { |o| raise OptionParser::InvalidOption.new(o) }
    end
    begin
      parser.parse(args)
    rescue ex : OptionParser::Exception
      STDERR.puts ex.message
      STDERR.puts parser
      return 2
    end
    if h = help
      puts h
      return 0
    end
    cases = begin
      load(file, args, subject)
    rescue ex : Case::Error
      STDERR.puts ex.message
      return 2
    end
    if cases.empty?
      STDERR.puts "no cases"
      return 2
    end
    unless Case::MODES.includes?(mode)
      STDERR.puts "unknown mode #{mode}"
      return 2
    end
    resolved = if mode == "offscreen"
                 binary
               else
                 Process.find_executable(binary) || (STDERR.puts "cannot find #{binary}"; return 2)
               end
    options = Runner::Options.new(resolved, out_dir, update, fail_fast, verbose)
    run_cases(cases, options, mode, show, subject)
  end

  # The cases of *file* named in *names*, in the file's order; all of
  # them when *names* is empty.
  private def self.load(file : String, names : Array(String), subject : Subject) : Array(Case)
    cases = Case.read(file, subject.keys)
    cases.each { |test| subject.check(test) }
    return cases if names.empty?
    missing = names - cases.map(&.name)
    raise Case::Error.new("#{file}: no case #{missing.join(", ")}") unless missing.empty?
    cases.select { |c| names.includes?(c.name) }
  end

  private def self.backend(mode : String, show : Bool, subject : Subject) : Backend
    case mode
    when "sway" then Backends::Sway.new(show)
    when "offscreen"
      worker = subject.worker || raise Backend::Error.new("#{subject.name} has no offscreen worker")
      Backends::Offscreen.new(worker)
    else Backends::KDE.new
    end
  end

  private def self.run_cases(cases : Array(Case), options : Runner::Options, mode : String, show : Bool,
                             subject : Subject) : Int32
    runner = begin
      Runner.new(options, backend(mode, show, subject), subject)
    rescue ex : Backend::Error | DBus::Error | KWin::Error | Input::Error | UInput::Error | Keymap::Error | Wayland::Error
      STDERR.puts "cannot start: #{ex.message}"
      return 1
    end
    failed = 0
    skipped = 0
    begin
      cases.each do |test|
        unless test.modes.empty? || test.modes.includes?(mode)
          skipped += 1
          STDOUT.puts "SKIP #{test.name} (#{test.modes.join(' ')} only)"
          next
        end
        STDOUT.puts "RUN  #{test.name}" if options.verbose
        result = runner.run(test)
        ms = result.elapsed.total_milliseconds.round.to_i
        if result.passed
          STDOUT.puts "PASS #{test.name} (#{ms} ms)"
        else
          failed += 1
          STDOUT.puts "FAIL #{test.name} (#{ms} ms): #{test.path}: #{result.message}"
          break if options.fail_fast
        end
      end
    ensure
      runner.close
    end
    verb = options.update ? "updated" : "passed"
    STDOUT.puts "#{cases.size - failed - skipped} #{verb}, #{failed} failed#{", #{skipped} skipped" if skipped > 0}"
    failed == 0 ? 0 : 1
  end
end
