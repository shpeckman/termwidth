# spec/text_spec.cr

require "./spec_helper"

private BREAK_TEST = "#{__DIR__}/data/GraphemeBreakTest.txt"

private def expected_clusters(line : String) : Array(Array(UInt32))
  out     = [] of Array(UInt32)
  current = [] of UInt32
  line.split(' ') do |token|
    case token
    when "\u00F7"
      out << current unless current.empty?
      current = [] of UInt32
    when "\u00D7", ""
    else
      current << token.to_u32(16)
    end
  end
  out << current unless current.empty?
  out
end

private def encode(expected : Array(Array(UInt32))) : Bytes
  io = IO::Memory.new
  expected.each { |cluster| cluster.each { |cp| io << cp.to_i.unsafe_chr } }
  io.to_slice
end

private def codepoints(cluster : Bytes) : Array(UInt32)
  out = [] of UInt32
  i   = 0
  while i < cluster.size
    cp, used = TermWidth::Utf8.decode(cluster, i)
    out << cp
    i += used
  end
  out
end

describe TermWidth::Segmenter do
  it "matches the Unicode grapheme break conformance suite" do
    segmenter = TermWidth::Segmenter::NARROW
    checked   = 0
    File.each_line(BREAK_TEST) do |line|
      body = line.split('#', 2)[0].strip
      next if body.empty?
      expected = expected_clusters(body)
      next if expected.empty?

      got = [] of Array(UInt32)
      segmenter.each(encode(expected)) { |cluster, _| got << codepoints(cluster) }
      got.should eq(expected)
      checked += 1
    end
    checked.should be > 700
  end

  it "reports the pinned Unicode version" do
    TermWidth::Tables::UNICODE_VERSION.should eq("17.0.0")
  end

  it "gives ascii one cell each" do
    widths("hello").should eq([1_u8, 1_u8, 1_u8, 1_u8, 1_u8])
  end

  it "gives east asian wide characters two cells" do
    widths("日本").should eq([2_u8, 2_u8])
  end

  it "folds a combining mark into its base cluster" do
    clusters("e\u0301").should eq([{"e\u0301", 1_u8}])
  end

  it "reports a leading combining mark as zero width" do
    widths("\u0301a").should eq([0_u8, 1_u8])
  end

  it "keeps a hangul syllable together" do
    clusters("\u1100\u1161\u11A8").map(&.[1]).should eq([2_u8])
  end

  it "keeps an emoji zwj sequence in one double-width cluster" do
    clusters("\u{1F468}\u200D\u{1F469}\u200D\u{1F467}").should eq([{"\u{1F468}\u200D\u{1F469}\u200D\u{1F467}", 2_u8}])
  end

  it "keeps a regional indicator pair in one double-width cluster" do
    widths("\u{1F1FA}\u{1F1F8}").should eq([2_u8])
  end

  it "splits four regional indicators into two flags" do
    widths("\u{1F1FA}\u{1F1F8}\u{1F1EF}\u{1F1F5}").should eq([2_u8, 2_u8])
  end

  it "keeps an emoji modifier sequence together" do
    widths("\u{1F44D}\u{1F3FB}").should eq([2_u8])
  end

  it "promotes a text presentation base through vs16" do
    widths("\u2764").should eq([1_u8])
    widths("\u2764\uFE0F").should eq([2_u8])
  end

  it "keeps a text presentation base narrow through vs15" do
    widths("\u2764\uFE0E").should eq([1_u8])
  end

  it "gives a keycap sequence two cells" do
    widths("1\uFE0F\u20E3").should eq([2_u8])
  end

  it "treats ambiguous width by policy" do
    widths("\u00A1").should eq([1_u8])
    widths("\u00A1", TermWidth::Segmenter::WIDE).should eq([2_u8])
  end

  it "leaves unambiguous widths untouched by the wide policy" do
    widths("a\u65E5", TermWidth::Segmenter::WIDE).should eq([1_u8, 2_u8])
  end

  it "does not break inside an indic conjunct" do
    widths("\u0915\u094D\u0937").should eq([1_u8])
  end

  it "breaks a devanagari cluster without a virama" do
    widths("\u0915\u0937").should eq([1_u8, 1_u8])
  end

  it "keeps a prepend with the following base" do
    clusters("\u0600\u0661").map(&.[1]).should eq([1_u8])
  end

  it "keeps CRLF as one cluster" do
    clusters("\r\n").size.should eq(1)
  end

  it "measures a mixed string in cells" do
    TermWidth::Segmenter::NARROW.measure("ab\u65E5\u{1F600}").should eq(6)
  end

  it "counts clusters rather than codepoints" do
    TermWidth::Segmenter::NARROW.count("e\u0301\u{1F1FA}\u{1F1F8}").should eq(2)
  end
end

private def spans(text : String) : Array(Tuple(String, UInt8, Bool))
  acc = [] of Tuple(String, UInt8, Bool)
  TermWidth::Segmenter::NARROW.each_span(text) { |span, width, ascii| acc << {String.new(span), width, ascii} }
  acc
end

describe "TermWidth::Segmenter#each_span" do
  it "merges printable ascii into runs and keeps the last byte pending" do
    spans("hello, 日本").should eq([
      {"hello,", 1_u8, true},
      {" ",      1_u8, false},
      {"日",      2_u8, false},
      {"本",      2_u8, false},
    ])
  end

  it "leaves a lone ascii byte as a plain cluster" do
    spans("a").should eq([{"a", 1_u8, false}])
  end

  it "closes a run that reaches the end of the input" do
    spans("ab").should eq([{"ab", 1_u8, true}])
    spans("日xyz").should eq([{"日", 2_u8, false}, {"xyz", 1_u8, true}])
  end

  it "keeps a combining mark with the byte after a run" do
    spans("abé").should eq([{"ab", 1_u8, true}, {"é", 1_u8, false}])
  end

  it "does not merge a multi-byte cluster into a following run" do
    spans("éabc!").should eq([{"é", 1_u8, false}, {"abc!", 1_u8, true}])
    spans("éabcé").should eq([{"é", 1_u8, false}, {"ab", 1_u8, true}, {"c", 1_u8, false}, {"é", 1_u8, false}])
  end

  it "breaks runs at control bytes" do
    spans("ab\ncd").should eq([
      {"a",  1_u8, true}, {"b", 1_u8, false}, {"\n", 0_u8, false},
      {"cd", 1_u8, true},
    ])
  end

  it "covers the input exactly and agrees with each" do
    rng    = Random.new(42)
    pieces = ["a", "b", "Z", " ", "~", "日", "é", "́", "\u{1F1FA}", "\u{1F468}‍\u{1F469}", "\n", "\r\n", "¡"]
    200.times do
      text     = String.build { |sb| rng.rand(0..24).times { sb << pieces.sample(rng) } }
      joined   = String.build { |sb| spans(text).each { |s| sb << s[0] } }
      expanded = [] of Tuple(String, UInt8)
      spans(text).each do |span, width, ascii|
        if ascii
          span.each_char { |ch| expanded << {ch.to_s, 1_u8} }
        else
          expanded << {span, width}
        end
      end
      joined.should eq(text)
      expanded.should eq(clusters(text))
      spans(text).each { |s, _, ascii| s.each_byte.all? { |b| b >= 0x20_u8 && b < 0x7F_u8 }.should be_true if ascii }
    end
  end
end

describe TermWidth::Utf8 do
  it "decodes every sequence length" do
    TermWidth::Utf8.decode("a".to_slice, 0).should eq({0x61_u32, 1})
    TermWidth::Utf8.decode("\u00E9".to_slice, 0).should eq({0xE9_u32, 2})
    TermWidth::Utf8.decode("\u65E5".to_slice, 0).should eq({0x65E5_u32, 3})
    TermWidth::Utf8.decode("\u{1F600}".to_slice, 0).should eq({0x1F600_u32, 4})
  end

  it "replaces a stray continuation byte" do
    TermWidth::Utf8.decode(Bytes[0x80_u8], 0).should eq({0xFFFD_u32, 1})
  end

  it "replaces an overlong encoding" do
    TermWidth::Utf8.decode(Bytes[0xC0_u8, 0x80_u8], 0).should eq({0xFFFD_u32, 1})
  end

  it "replaces a surrogate encoding" do
    TermWidth::Utf8.decode(Bytes[0xED_u8, 0xA0_u8, 0x80_u8], 0).should eq({0xFFFD_u32, 1})
  end

  it "replaces a codepoint past the maximum" do
    TermWidth::Utf8.decode(Bytes[0xF5_u8, 0x80_u8, 0x80_u8, 0x80_u8], 0).should eq({0xFFFD_u32, 1})
  end

  it "consumes the maximal subpart of a truncated sequence" do
    TermWidth::Utf8.decode(Bytes[0xE6_u8, 0x97_u8], 0).should eq({0xFFFD_u32, 2})
  end

  it "never reads past the end of the slice" do
    TermWidth::Utf8.decode(Bytes[0xF0_u8], 0).should eq({0xFFFD_u32, 1})
  end
end
