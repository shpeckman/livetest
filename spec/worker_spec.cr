require "./spec_helper"

private class FakeSurface
  include Livetest::Worker::Surface

  getter log = [] of String
  @clip = "hi"

  def shot : {Int32, Int32, Bytes}
    {1, 2, Bytes[1, 2, 3, 4, 5, 6, 7, 8]}
  end

  def key(code : UInt32, down : Bool) : Nil
    @log << "key #{code} #{down}"
  end

  def move(x : Float64, y : Float64) : Nil
    @log << "move #{x} #{y}"
  end

  def button(code : UInt32, down : Bool) : Nil
    @log << "button #{code} #{down}"
  end

  def scroll(dy : Int32, dx : Int32) : Nil
    @log << "scroll #{dy} #{dx}"
  end

  def resize(width : Int32, height : Int32) : Nil
    raise ArgumentError.new("too small") if width < 10
    @log << "resize #{width} #{height}"
  end

  def close : Nil
    @log << "close"
  end

  def title : String
    "t"
  end

  def clipboard(&block : String ->) : Nil
    block.call(@clip)
  end

  def copy(text : String) : Nil
    @clip = text
  end
end

# Sends *line* to *worker* through *conn*; returns the answer line.
private def ask(worker : Livetest::Worker, conn : UNIXSocket, line : String) : String
  conn << line << '\n'
  conn.flush
  worker.readable
  conn.gets.to_s
end

describe Livetest::Worker do
  it "answers the harness's commands" do
    path = File.tempname("livetest-worker")
    server = UNIXServer.new(path)
    ENV["LIVETEST_CONTROL"] = path
    surface = FakeSurface.new
    worker = Livetest::Worker.new(surface)
    conn = server.accept
    begin
      ask(worker, conn, "key 30 1").should eq("ok")
      ask(worker, conn, "move 1.5 2").should eq("ok")
      ask(worker, conn, "button 272 0").should eq("ok")
      ask(worker, conn, "scroll -1 0").should eq("ok")
      ask(worker, conn, "resize 300 200").should eq("ok")
      ask(worker, conn, "close").should eq("ok")
      surface.log.should eq(["key 30 true", "move 1.5 2.0", "button 272 false", "scroll -1 0", "resize 300 200", "close"])
      ask(worker, conn, "title").should eq("ok 74")
      ask(worker, conn, "copy 616263").should eq("ok")
      ask(worker, conn, "clipboard").should eq("ok 616263")
      ask(worker, conn, "shot").should eq("ok 1 2")
      pixels = Bytes.new(8)
      conn.read_fully(pixels)
      pixels.should eq(Bytes[1, 2, 3, 4, 5, 6, 7, 8])
      ask(worker, conn, "resize 1 1").should eq("error too small")
      ask(worker, conn, "jump").should eq("error unknown command jump")
    ensure
      conn.close
      server.close
      ENV.delete("LIVETEST_CONTROL")
    end
  end

  it "refuses to run outside the harness" do
    expect_raises(Livetest::Worker::Error, "LIVETEST_CONTROL is not set") { Livetest::Worker.new(FakeSurface.new) }
  end
end
