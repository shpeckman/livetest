require "compress/zlib"
require "digest/crc32"

# :nodoc:
# A rectangle in pixels.
record Livetest::Rect, x : Int32, y : Int32, width : Int32, height : Int32 do
  def includes?(px : Int32, py : Int32) : Bool
    px >= x && py >= y && px < x + width && py < y + height
  end
end

# :nodoc:
# An 8-bit RGBA image with a PNG codec (8-bit, non-interlaced) and a
# tolerant comparison that produces a diff image.
class Livetest::Image
  class Error < Exception
  end

  # The outcome of `#compare`: the differing pixel count and, when the sizes
  # match, a diff image with the differences in red.
  record Comparison, differing : Int32, total : Int32, diff : Image?

  private SIGNATURE = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

  getter width : Int32
  getter height : Int32
  getter pixels : Bytes

  def initialize(@width : Int32, @height : Int32, pixels : Bytes? = nil)
    raise Error.new("bad image size #{@width}x#{@height}") if @width < 0 || @height < 0
    @pixels = pixels || Bytes.new(@width * @height * 4)
    raise Error.new("pixel data does not match #{@width}x#{@height}") unless @pixels.size == @width * @height * 4
  end

  def ==(other : Image) : Bool
    width == other.width && height == other.height && pixels == other.pixels
  end

  # Returns the part of the image inside *rect*, clipped to the image.
  def crop(rect : Rect) : Image
    x0 = rect.x.clamp(0, width)
    y0 = rect.y.clamp(0, height)
    x1 = (rect.x + rect.width).clamp(x0, width)
    y1 = (rect.y + rect.height).clamp(y0, height)
    dst = Image.new(x1 - x0, y1 - y0)
    row = dst.width * 4
    dst.height.times do |y|
      src = ((y0 + y) * width + x0) * 4
      @pixels[src, row].copy_to(dst.pixels[y * row, row])
    end
    dst
  end

  # Compares with *expected*: a pixel differs when a channel differs by more
  # than *tolerance*; pixels inside *masks* are ignored.
  def compare(expected : Image, tolerance : Int32 = 0, masks : Array(Rect) = [] of Rect) : Comparison
    total = Math.max(width * height, expected.width * expected.height)
    return Comparison.new(total, total, nil) unless width == expected.width && height == expected.height
    diff = Image.new(width, height)
    differing = 0
    a = @pixels
    b = expected.pixels
    d = diff.pixels
    height.times do |y|
      width.times do |x|
        i = (y * width + x) * 4
        masked = masks.any?(&.includes?(x, y))
        delta = 0
        4.times { |c| delta = Math.max(delta, (a[i + c].to_i32 - b[i + c].to_i32).abs) }
        if !masked && delta > tolerance
          differing += 1
          d[i] = 255_u8
          d[i + 1] = 0_u8
          d[i + 2] = 0_u8
        else
          gray = ((a[i].to_i32 * 3 + a[i + 1].to_i32 * 6 + a[i + 2].to_i32) // 10 // 3 + (masked ? 40 : 0)).to_u8
          d[i] = gray
          d[i + 1] = gray
          d[i + 2] = masked ? (gray.to_i32 + 60).clamp(0, 255).to_u8 : gray
        end
        d[i + 3] = 255_u8
      end
    end
    Comparison.new(differing, total, diff)
  end

  def self.read(path : String) : Image
    File.open(path) { |f| read(f) }
  rescue ex : IO::Error | File::Error
    raise Error.new("#{path}: #{ex.message}")
  end

  # Decodes a PNG: bit depth 8, any colour type, no interlacing.
  def self.read(io : IO) : Image
    sig = Bytes.new(8)
    io.read_fully(sig)
    raise Error.new("not a PNG") unless sig == SIGNATURE
    width = height = 0
    color = depth = 0
    palette = Bytes.empty
    trns = Bytes.empty
    idat = IO::Memory.new
    loop do
      len = io.read_bytes(UInt32, IO::ByteFormat::BigEndian).to_i32
      type = io.read_string(4)
      data = Bytes.new(len)
      io.read_fully(data)
      io.skip(4)
      case type
      when "IHDR"
        width = IO::ByteFormat::BigEndian.decode(UInt32, data[0, 4]).to_i32
        height = IO::ByteFormat::BigEndian.decode(UInt32, data[4, 4]).to_i32
        depth = data[8].to_i32
        color = data[9].to_i32
        raise Error.new("PNG bit depth #{depth} is not supported") unless depth == 8
        raise Error.new("interlaced PNG is not supported") unless data[12] == 0
      when "PLTE" then palette = data
      when "tRNS" then trns = data
      when "IDAT" then idat.write(data)
      when "IEND" then break
      end
    end
    channels = case color
               when 0 then 1
               when 2 then 3
               when 3 then 1
               when 4 then 2
               when 6 then 4
               else        raise Error.new("PNG colour type #{color} is not supported")
               end
    idat.rewind
    raw = Compress::Zlib::Reader.open(idat) { |z| z.getb_to_end }
    stride = width * channels
    raise Error.new("truncated PNG data") if raw.size < (stride + 1) * height
    image = Image.new(width, height)
    prev = Bytes.new(stride)
    cur = Bytes.new(stride)
    height.times do |y|
      filter = raw[y * (stride + 1)]
      line = raw[y * (stride + 1) + 1, stride]
      unfilter(filter, line, prev, cur, channels)
      expand(cur, image.pixels[y * width * 4, width * 4], color, palette, trns)
      prev, cur = cur, prev
    end
    image
  end

  private def self.unfilter(filter : UInt8, line : Bytes, prev : Bytes, cur : Bytes, bpp : Int32) : Nil
    line.size.times do |i|
      a = i >= bpp ? cur[i - bpp].to_i32 : 0
      b = prev[i].to_i32
      c = i >= bpp ? prev[i - bpp].to_i32 : 0
      x = line[i].to_i32
      v = case filter
          when 0 then x
          when 1 then x + a
          when 2 then x + b
          when 3 then x + (a + b) // 2
          when 4
            p = a + b - c
            pa = (p - a).abs
            pb = (p - b).abs
            pc = (p - c).abs
            x + (pa <= pb && pa <= pc ? a : (pb <= pc ? b : c))
          else raise Error.new("bad PNG filter #{filter}")
          end
      cur[i] = (v & 0xFF).to_u8
    end
  end

  private def self.expand(src : Bytes, dst : Bytes, color : Int32, palette : Bytes, trns : Bytes) : Nil
    n = dst.size // 4
    n.times do |i|
      r = g = b = 0_u8
      a = 255_u8
      case color
      when 0
        r = g = b = src[i]
        a = 0_u8 if trns.size >= 2 && trns[1] == src[i]
      when 2
        r, g, b = src[i * 3], src[i * 3 + 1], src[i * 3 + 2]
      when 3
        idx = src[i].to_i32
        if idx * 3 + 2 < palette.size
          r, g, b = palette[idx * 3], palette[idx * 3 + 1], palette[idx * 3 + 2]
        end
        a = trns[idx] if idx < trns.size
      when 4
        r = g = b = src[i * 2]
        a = src[i * 2 + 1]
      else
        r, g, b, a = src[i * 4], src[i * 4 + 1], src[i * 4 + 2], src[i * 4 + 3]
      end
      dst[i * 4] = r
      dst[i * 4 + 1] = g
      dst[i * 4 + 2] = b
      dst[i * 4 + 3] = a
    end
  end

  # Writes the image as an 8-bit RGBA PNG, creating the parent directory.
  def write(path : String) : Nil
    Dir.mkdir_p(File.dirname(path))
    File.open(path, "w") { |f| write(f) }
  end

  def write(io : IO) : Nil
    io.write(SIGNATURE)
    ihdr = IO::Memory.new
    ihdr.write_bytes(width.to_u32, IO::ByteFormat::BigEndian)
    ihdr.write_bytes(height.to_u32, IO::ByteFormat::BigEndian)
    ihdr.write(Bytes[8, 6, 0, 0, 0])
    chunk(io, "IHDR", ihdr.to_slice)
    data = IO::Memory.new
    Compress::Zlib::Writer.open(data) do |z|
      row = width * 4
      height.times do |y|
        z.write_byte(0_u8)
        z.write(@pixels[y * row, row])
      end
    end
    chunk(io, "IDAT", data.to_slice)
    chunk(io, "IEND", Bytes.empty)
  end

  private def chunk(io : IO, type : String, data : Bytes) : Nil
    io.write_bytes(data.size.to_u32, IO::ByteFormat::BigEndian)
    head = type.to_slice
    io.write(head)
    io.write(data)
    crc = Digest::CRC32.update(data, Digest::CRC32.update(head, Digest::CRC32.initial))
    io.write_bytes(crc, IO::ByteFormat::BigEndian)
  end
end
