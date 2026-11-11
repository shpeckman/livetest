# :nodoc:
# One process under test, with a unique app id and a FIFO (in
# `LIVETEST_FIFO`) the case's commands write lines to.
class Livetest::App
  class Error < Exception
  end

  getter app_id : String
  getter fifo : String
  getter process : Process

  @lines = Channel(String).new(256)
  @fifo_io : IO::FileDescriptor
  @status : Process::Status? = nil
  @exited = Channel(Nil).new(1)

  # Starts *program* with *args* and the extra environment *env*; its
  # output goes to *log*, *dir* is its working directory.
  def initialize(program : String, args : Array(String), env : Hash(String, String?), @app_id : String,
                 dir : String, log : String)
    dir = File.expand_path(dir)
    Dir.mkdir_p(dir)
    @fifo = File.join(dir, ".fifo")
    File.delete?(@fifo)
    raise Error.new("mkfifo #{@fifo}: #{Errno.value.message}") if LibC.mkfifo(@fifo, 0o600) != 0
    fd = LibC.open(@fifo, LibC::O_RDWR | LibC::O_NONBLOCK | LibC::O_CLOEXEC)
    raise Error.new("open #{@fifo}: #{Errno.value.message}") if fd < 0
    @fifo_io = IO::FileDescriptor.new(fd)
    spawn read_lines
    env = env.merge({"LIVETEST_FIFO" => @fifo, "LIVETEST_DIR" => dir} of String => String?)
    binary = program
    output = File.open(log, "w")
    @process = begin
      Process.new(binary, args, env: env, chdir: dir, output: output, error: output)
    rescue ex : IO::Error | File::Error
      raise Error.new("cannot start #{binary}: #{ex.message}")
    ensure
      output.close
    end
    process = @process
    spawn do
      @status = process.wait
      @exited.send(nil)
    end
  end

  private def read_lines : Nil
    while line = @fifo_io.gets
      @lines.send(line)
    end
  rescue IO::Error
  end

  def exited? : Bool
    !@status.nil?
  end

  def status : Process::Status?
    @status
  end

  # Waits for a FIFO line equal to *text*, skipping others; returns false
  # on timeout.
  def expect(text : String, timeout : Time::Span) : Bool
    deadline = Time.instant + timeout
    loop do
      left = deadline - Time.instant
      return false if left <= Time::Span.zero
      select
      when line = @lines.receive
        return true if line == text
      when timeout(left)
        return false
      end
    end
  end

  # Waits for the process to exit; returns its status or nil on timeout.
  def wait(timeout : Time::Span) : Process::Status?
    return @status if @status
    select
    when @exited.receive
      @exited.send(nil)
      @status
    when timeout(timeout)
      nil
    end
  end

  # Terminates the process if it still runs and removes the FIFO.
  def stop : Nil
    unless exited?
      @process.signal(Signal::TERM) rescue nil
      if wait(2.seconds).nil?
        @process.signal(Signal::KILL) rescue nil
        wait(2.seconds)
      end
    end
    @fifo_io.close rescue nil
    File.delete?(@fifo)
  end
end
