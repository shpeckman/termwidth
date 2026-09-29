# spec/cluster_spec.cr

require "./spec_helper"
require "./support/reference"

private BREAK_TEST = "#{__DIR__}/data/GraphemeBreakTest.txt"

private PIECES = [
  "a", "b", "Z", " ", "~", "0", "\t", "\n", "\r\n", "\e", "\u007F", "é", "¡",
  "́", "日", "\u{1F1FA}", "\u{1F1F8}", "\u{1F468}‍\u{1F469}",
  "क्ष", "❤️", "1️⃣", "각", "؀",
  "\u{1F1F3}", "\u{1F44D}\u{1F3FD}", "\u{1F3FD}", "\u231A\uFE0E", "1\u20E3", "\u1100\u1161\u11A8",
  "\u1161", "\uFE0E", "\uFE0F", "\u20E3", "\u200D", "\u2764\u200D\u{1F525}", "\u0085",
]

private RULE_SETS = [
  WidthProfile::UNICODE.rules,
  WidthProfile::UNICODE_WIDE.rules,
  Rule::None,
  Rule::PairFlags | Rule::ModifierMerges | Rule::Vs16Widens,
  Rule::Clusters,
  Rule::All,
]

private def random_text(rng : Random) : Bytes
  String.build { |sb| rng.rand(0..40).times { sb << PIECES.sample(rng) } }.to_slice
end

private def random_bytes(rng : Random) : Bytes
  Bytes.new(rng.rand(0..96)) do
    case rng.rand(10)
    when 0 then rng.rand(0x00..0x1F).to_u8
    when 1 then 0x7F_u8
    when 2 then rng.rand(0x80..0xFF).to_u8
    else        rng.rand(0x20..0x7E).to_u8
    end
  end
end

private def c_spans(bytes : Bytes, rules : Rule) : Array(KernelReference::Span)
  result = [] of KernelReference::Span
  seg    = Segmenter.new(WidthProfile.new(rules))
  seg.each_span(bytes) do |span, width, ascii|
    result << KernelReference::Span.new((span.to_unsafe - bytes.to_unsafe).to_i32, span.size, width, ascii)
  end
  result
end

private def capped_clusters(bytes : Bytes, rules : Rule, cap : Int32) : Array(Tuple(Int32, Int32, UInt8))
  recs  = Slice(Cluster).new(cap, Cluster.new)
  spans = [] of KernelReference::Span
  off   = 0
  while off < bytes.size
    count = TermWidth.segment(bytes, off, rules.value, recs)
    count.should be > 0
    count.should be <= cap
    count.times do |k|
      rec = recs[k]
      spans << KernelReference::Span.new(off + rec.start, rec.length, rec.width, (rec.flags & CLUSTER_ASCII_RUN) != 0)
    end
    off += recs[count - 1].start + recs[count - 1].length
  end
  KernelReference.clusters(spans)
end

describe TermWidth do
  it "keeps the public cluster record size" do
    sizeof(Cluster).should eq(12)
  end

  it "scans printable ascii like the reference" do
    rng = Random.new(1)
    400.times do
      bytes = random_bytes(rng)
      (0..bytes.size).each do |from|
        got = TermWidth.scan_printable(bytes, from)
        fail "scan_printable #{bytes} @#{from}" unless got == KernelReference.scan_printable(bytes, from)
      end
    end
  end

  it "rejects out-of-range scan and segment requests" do
    recs = Slice(Cluster).new(4, Cluster.new)
    expect_raises(IndexError) { TermWidth.scan_printable(Bytes.new(3), 4) }
    expect_raises(IndexError) { TermWidth.segment(Bytes.new(3), 4, 0_u32, recs) }
  end

  it "segments like the reference on the conformance data" do
    lines = File.read_lines(BREAK_TEST).compact_map do |line|
      body = line.split('#', 2)[0].strip
      next if body.empty?
      String.build do |sb|
        body.split(' ').each { |tok| sb << tok.to_i(16).unsafe_chr unless tok == "÷" || tok == "×" || tok.empty? }
      end.to_slice
    end
    lines.each do |bytes|
      RULE_SETS.each do |rules|
        got = c_spans(bytes, rules)
        fail "#{String.new(bytes).inspect} rules=#{rules}" unless got == KernelReference.spans(bytes, rules)
      end
    end
  end

  it "segments random text and malformed bytes like the reference" do
    rng = Random.new(6)
    500.times do
      bytes = rng.next_bool ? random_text(rng) : random_bytes(rng)
      (RULE_SETS + [Rule.new(rng.rand(0_u32..Rule::All.value))]).each do |rules|
        got = c_spans(bytes, rules)
        fail "#{bytes} rules=#{rules}" unless got == KernelReference.spans(bytes, rules)
      end
    end
  end

  it "resumes from a full record buffer without changing the clusters" do
    rng = Random.new(7)
    300.times do
      bytes    = rng.next_bool ? random_text(rng) : random_bytes(rng)
      rules    = RULE_SETS.sample(rng)
      expected = KernelReference.clusters(KernelReference.spans(bytes, rules))
      {1, 2, 3, 5, 64}.each do |cap|
        got = capped_clusters(bytes, rules, cap)
        fail "cap=#{cap} rules=#{rules} #{bytes}" unless got == expected
      end
    end
  end

  it "segments input larger than one record batch" do
    text = ("ab日é " * 200).to_slice
    RULE_SETS.each { |rules| c_spans(text, rules).should eq(KernelReference.spans(text, rules)) }
  end
end
