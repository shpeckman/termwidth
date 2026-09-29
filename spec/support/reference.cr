# spec/support/reference.cr

module KernelReference
  record Span, start : Int32, length : Int32, width : UInt8, ascii : Bool

  VS15          = 0xFE0E_u32
  VS16          = 0xFE0F_u32
  ZWJ           = 0x200D_u32
  KEYCAP        = 0x20E3_u32
  RI_RANGE      = 0x1F1E6_u32..0x1F1FF_u32
  MODIFIERS     = 0x1F3FB_u32..0x1F3FF_u32
  TRAILING_JAMO = {0x1160_u32..0x11FF_u32, 0xD7B0_u32..0xD7FF_u32}

  alias Rule = TermWidth::Rule

  def self.control?(cp : UInt32) : Bool
    cp < 0x20_u32 || (0x7F_u32..0x9F_u32).includes?(cp)
  end

  def self.cp_width(cp : UInt32, rules : Rule) : UInt8
    prop = TermWidth::Props.lookup(cp)
    w    = TermWidth::Props.width(prop)
    w    = 2_u8 if rules.ambiguous_wide? && TermWidth::Props.ambiguous?(prop)
    w    = 0_u8 if !rules.clusters? && TRAILING_JAMO.any?(&.includes?(cp))
    w
  end

  struct Cluster
    getter ri        = 0
    getter base_ri   = false
    getter base_pict = false

    @max_w     = 0_u8
    @vs16      = false
    @vs15      = false
    @zwj       = false
    @keycap    = false
    @base_seen = false
    @spacing   = 0

    def self.ascii : Cluster
      cluster = new
      cluster.absorb(0x61_u32, 1_u8)
      cluster
    end

    def absorb(cp : UInt32, w : UInt8) : Nil
      @max_w = w if w > @max_w
      @spacing += 1 if w > 0_u8
      @vs16   = true if cp == VS16
      @vs15   = true if cp == VS15
      @zwj    = true if cp == ZWJ
      @keycap = true if cp == KEYCAP
      @ri += 1 if RI_RANGE.includes?(cp)
      return if @base_seen
      @base_pict = TermWidth::Props.pictographic?(TermWidth::Props.lookup(cp))
      @base_ri   = RI_RANGE.includes?(cp)
      @base_seen = true
    end

    def width(rules : Rule) : UInt8
      return 0_u8 if @max_w == 0_u8
      return 2_u8 if @ri >= 2
      return (rules.lone_ri_wide? ? 2_u8 : 1_u8) if @ri == 1 && @base_ri
      return 2_u8 if rules.spacing_widens? && @spacing >= 2 && !@base_pict && !@base_ri
      return 1_u8 if @vs15 && (rules.vs15_narrows? || @max_w == 1_u8)
      return (rules.keycap_wide? ? 2_u8 : 1_u8) if @keycap && @vs16
      return 2_u8 if @vs16 && rules.vs16_widens?
      return 2_u8 if rules.clusters? && @zwj && @base_pict
      @max_w
    end
  end

  def self.boundary?(acc : Cluster, prev : UInt32, cp : UInt32, w : UInt8, rules : Rule, gstate : TermWidth::Grapheme::State*) : Bool
    if rules.clusters?
      return true if TermWidth::Grapheme.break?(prev, cp, gstate)
      return !rules.pair_flags? if RI_RANGE.includes?(cp)
      return !rules.modifier_merges? if MODIFIERS.includes?(cp)
      false
    else
      return true if control?(cp) || control?(prev)
      return false if w == 0_u8
      return !(rules.pair_flags? && acc.ri == 1 && acc.base_ri) if RI_RANGE.includes?(cp)
      return !(rules.modifier_merges? && acc.base_pict) if MODIFIERS.includes?(cp)
      true
    end
  end

  def self.printable?(b : UInt8) : Bool
    b >= 0x20_u8 && b < 0x7F_u8
  end

  def self.scan_printable(bytes : Bytes, from : Int32) : Int32
    i = from
    while i < bytes.size && printable?(bytes[i])
      i += 1
    end
    i - from
  end

  def self.spans(bytes : Bytes, rules : Rule) : Array(Span)
    result = [] of Span
    n      = bytes.size
    start  = 0
    i      = 0
    have   = false
    prev   = 0_u32
    gstate = TermWidth::Grapheme::State.new
    acc    = Cluster.new

    while i < n
      b = bytes[i]
      cp, used = TermWidth::Utf8.decode(bytes, i)
      w        = cp_width(cp, rules)
      boundary = !have || boundary?(acc, prev, cp, w, rules, pointerof(gstate))

      if boundary && printable?(b)
        run_start = i
        if have
          if i - start == 1 && printable?(bytes[start])
            run_start = start
          else
            result << Span.new(start, i - start, acc.width(rules), false)
          end
        end

        j = i
        while j + 1 < n && printable?(bytes[j + 1])
          j += 1
        end

        if j + 1 == n
          result << Span.new(run_start, n - run_start, 1_u8, n - run_start > 1)
          return result
        end
        result << Span.new(run_start, j - run_start, 1_u8, true) if j > run_start

        start  = j
        have   = true
        acc    = Cluster.ascii
        prev   = bytes[j].to_u32
        gstate = TermWidth::Grapheme::State.new
        i      = j + 1
        next
      end

      if boundary && have
        result << Span.new(start, i - start, acc.width(rules), false)
        start = i
        acc   = Cluster.new
      end

      acc.absorb(cp, w)
      have = true
      prev = cp
      i += used
    end

    result << Span.new(start, n - start, acc.width(rules), false) if have
    result
  end

  def self.clusters(spans : Array(Span)) : Array(Tuple(Int32, Int32, UInt8))
    result = [] of Tuple(Int32, Int32, UInt8)
    spans.each do |s|
      if s.ascii
        s.length.times { |k| result << {s.start + k, 1, 1_u8} }
      else
        result << {s.start, s.length, s.width}
      end
    end
    result
  end
end
