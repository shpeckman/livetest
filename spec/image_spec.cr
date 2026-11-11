require "./spec_helper"

private def gradient(w : Int32, h : Int32) : Livetest::Image
  img = Livetest::Image.new(w, h)
  h.times do |y|
    w.times do |x|
      i = (y * w + x) * 4
      img.pixels[i] = (x * 9).to_u8!
      img.pixels[i + 1] = (y * 7).to_u8!
      img.pixels[i + 2] = ((x + y) * 3).to_u8!
      img.pixels[i + 3] = 255_u8
    end
  end
  img
end

describe Livetest::Image do
  it "writes and reads PNG losslessly" do
    img = gradient(17, 9)
    io = IO::Memory.new
    img.write(io)
    io.rewind
    Livetest::Image.read(io).should eq(img)
  end

  it "counts differing pixels with tolerance and masks" do
    a = gradient(10, 10)
    b = gradient(10, 10)
    b.pixels[0] = b.pixels[0] &+ 3
    b.pixels[(5 * 10 + 5) * 4 + 1] = 200_u8
    r = b.compare(a)
    {r.differing, r.total}.should eq({2, 100})
    r.diff.should_not be_nil
    b.compare(a, tolerance: 3).differing.should eq(1)
    b.compare(a, tolerance: 3, masks: [Livetest::Rect.new(5, 5, 1, 1)]).differing.should eq(0)
  end

  it "reports a size mismatch without a diff" do
    r = gradient(4, 4).compare(gradient(4, 5))
    r.diff.should be_nil
    r.differing.should eq(r.total)
  end

  it "crops" do
    img = gradient(8, 8)
    c = img.crop(Livetest::Rect.new(2, 3, 4, 2))
    {c.width, c.height}.should eq({4, 2})
    c.pixels[0, 4].should eq(img.pixels[(3 * 8 + 2) * 4, 4])
  end
end
