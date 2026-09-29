# tool/verify_unicode.cr

require "../src/termwidth"

module Verify
  DATA = "#{__DIR__}/../spec/data/GraphemeBreakTest.txt"

  def self.clusters_of(line : String) : Array(Array(UInt32))
    out     = [] of Array(UInt32)
    current = [] of UInt32
    line.split(' ') do |tok|
      case tok
      when "\u00F7"
        out << current unless current.empty?
        current = [] of UInt32
      when "\u00D7", ""
      else
        current << tok.to_u32(16)
      end
    end
    out << current unless current.empty?
    out
  end

  def self.encode(expected : Array(Array(UInt32))) : Bytes
    io = IO::Memory.new
    expected.each { |cluster| cluster.each { |cp| io << cp.to_i.unsafe_chr } }
    io.to_slice
  end

  def self.decode(cluster : Bytes) : Array(UInt32)
    out = [] of UInt32
    j   = 0
    while j < cluster.size
      cp, used = TermWidth::Utf8.decode(cluster, j)
      out << cp
      j += used
    end
    out
  end

  def self.run : Int32
    seg      = TermWidth::Segmenter::NARROW
    pass     = 0
    fail     = 0
    failures = [] of String

    File.each_line(DATA) do |line|
      body = line.split('#', 2)[0].strip
      next if body.empty?
      expected = clusters_of(body)
      next if expected.empty?

      got = [] of Array(UInt32)
      seg.each(encode(expected)) { |cluster, _| got << decode(cluster) }

      if got == expected
        pass += 1
      else
        fail += 1
        if failures.size < 12
          failures << "#{body}\n  want #{expected.map(&.map(&.to_s(16)))}\n  got  #{got.map(&.map(&.to_s(16)))}"
        end
      end
    end

    puts "GraphemeBreakTest: pass=#{pass} fail=#{fail}"
    failures.each { |f| puts f }
    fail
  end
end

exit(Verify.run == 0 ? 0 : 1)
