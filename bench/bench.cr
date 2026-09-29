# bench/bench.cr
require "../src/termwidth"

module TermWidth::Bench
  WARMUP      = 0.15
  CALCULATION =  0.5

  NARROW = Segmenter::NARROW
  WIDE   = Segmenter::WIDE

  CORPORA = [
    {"ascii",    "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod. " * 32},
    {"latin",    "Café naïve résumé voilà — é ä ô ù ñ. " * 48},
    {"cjk",      "漢字かな交じり文と日本語のテキスト表示幅を測定するための文字列です。" * 32},
    {"hangul",   "각난달람만밥삿안잘참칼탈판한" * 64},
    {"conjunct", "क क्ष त्र ज्ञ द्ध र्क प्र श्र स्त ह्न त्त" * 64},
    {"emoji",    "👨‍👩‍👧👍🏽❤️⌚︎1️⃣🇳🇱🇯🇵🙂🚀✨🎉🔥" * 64},
    {"mixed",    "ok 漢字 👨‍👩‍👧 é क्ष 각 🇳🇱!\n" * 64},
  ]

  def self.run(label : String, bytes : Int32, & : -> Int32) : Nil
    total = 0_i64
    mark  = Time.instant
    while (Time.instant - mark).total_seconds < WARMUP
      total += yield
    end

    iters = 0_i64
    mark  = Time.instant
    loop do
      total += yield
      iters += 1
      break if (Time.instant - mark).total_seconds >= CALCULATION
    end
    seconds = (Time.instant - mark).total_seconds
    raise "unreachable" if total < 0

    STDOUT.printf "%-32s %14.0f ops/s %12.1f MB/s\n", label, iters / seconds,
      bytes.to_i64 * iters / seconds / 1e6
  end

  def self.section(title : String) : Nil
    puts
    puts title
  end

  def self.main : Nil
    puts "termwidth #{TermWidth::VERSION} on crystal #{Crystal::VERSION}"
    CORPORA.each { |name, text| puts "corpus #{name}: #{text.bytesize} bytes" }

    section "Segmenter#measure"
    CORPORA.each do |name, text|
      run("measure/narrow/#{name}", text.bytesize) { NARROW.measure(text) }
      run("measure/wide/#{name}", text.bytesize) { WIDE.measure(text) }
    end

    section "Segmenter#count"
    CORPORA.each do |name, text|
      run("count/#{name}", text.bytesize) { NARROW.count(text) }
    end

    section "Segmenter#each"
    CORPORA.each do |name, text|
      run("each/#{name}", text.bytesize) do
        sum = 0
        NARROW.each(text) { |cluster, width| sum += cluster.size * width }
        sum
      end
    end

    section "Segmenter#each_span"
    CORPORA.each do |name, text|
      run("each_span/#{name}", text.bytesize) do
        sum = 0
        NARROW.each_span(text) { |span, width, ascii| sum += ascii ? span.size : span.size * width }
        sum
      end
    end

    section "TermWidth.segment"
    rules = WidthProfile::UNICODE.rules.value
    dst = uninitialized StaticArray(Cluster, SEGMENT_BATCH)
    recs = dst.to_slice
    CORPORA.each do |name, text|
      bytes = text.to_slice
      run("segment/#{name}", bytes.size) do
        off     = 0
        emitted = 0
        while off < bytes.size
          count = TermWidth.segment(bytes, off, rules, recs)
          break if count == 0
          emitted += count
          last = recs.unsafe_fetch(count - 1)
          off += last.start + last.length
        end
        emitted
      end
    end

    section "TermWidth.scan_printable"
    ascii = CORPORA[0][1].to_slice
    run("scan_printable/ascii", ascii.size) { TermWidth.scan_printable(ascii) }

    section "Segmenter#codepoint_width"
    run("codepoint_width/cjk-sweep", 0) do
      sum = 0
      cp  = 0x4E00_u32
      while cp < 0x9FFF_u32
        sum += NARROW.codepoint_width(cp)
        cp += 1
      end
      sum
    end

    section "WidthProfile.categories"
    CORPORA.each do |name, text|
      run("categories/#{name}", text.bytesize) { WidthProfile.categories(text).value.to_i32 }
    end

    section "WidthProfile.infer"
    samples = WidthProfile::CALIBRATION.map { |text| WidthProfile::Sample.new(text, NARROW.measure(text)) }
    run("infer/calibration", 0) { WidthProfile.infer(samples).rules.value.to_i32 }
  end
end

TermWidth::Bench.main
