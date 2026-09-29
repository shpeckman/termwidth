# src/termwidth/cluster.cr
require "./utf8"
require "./props"
require "./grapheme"

module TermWidth
  struct Cluster
    getter start    : Int32
    getter length   : Int32
    getter width    : UInt8
    getter flags    : UInt8
    getter reserved : UInt16

    def initialize(@start : Int32 = 0, @length : Int32 = 0, @width : UInt8 = 0_u8,
                   @flags : UInt8 = 0_u8, @reserved : UInt16 = 0_u16)
    end
  end

  private struct ClusterState
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

    def self.ascii : ClusterState
      state = new
      state.absorb(0x61_u32, Props.lookup(0x61_u32), 1_u8)
      state
    end

    def absorb(cp : UInt32, prop : UInt8, w : UInt8) : Nil
      @max_w = w if w > @max_w
      @spacing += 1 if w > 0_u8 && @spacing < 2
      @vs16    = true if cp == VS16
      @vs15    = true if cp == VS15
      @zwj     = true if cp == ZWJ
      @keycap  = true if cp == KEYCAP
      regional = cp >= RI_FIRST && cp <= RI_LAST
      @ri += 1 if regional
      return if @base_seen
      @base_pict = Props.pictographic?(prop)
      @base_ri   = regional
      @base_seen = true
    end

    def width(rules : UInt32) : UInt8
      return 0_u8 if @max_w == 0_u8
      return 2_u8 if @ri >= 2
      return ((rules & RULE_LONE_RI_WIDE) != 0_u32 ? 2_u8 : 1_u8) if @ri == 1 && @base_ri
      return 2_u8 if (rules & RULE_SPACING_WIDENS) != 0_u32 && @spacing >= 2 && !@base_pict && !@base_ri
      return 1_u8 if @vs15 && ((rules & RULE_VS15_NARROWS) != 0_u32 || @max_w == 1_u8)
      return ((rules & RULE_KEYCAP_WIDE) != 0_u32 ? 2_u8 : 1_u8) if @keycap && @vs16
      return 2_u8 if @vs16 && (rules & RULE_VS16_WIDENS) != 0_u32
      return 2_u8 if (rules & RULE_CLUSTERS) != 0_u32 && @zwj && @base_pict
      @max_w
    end
  end

  CLUSTER_ASCII_RUN = 1_u8
  SEGMENT_BATCH     =   64

  RULE_CLUSTERS        =   1_u32
  RULE_AMBIGUOUS_WIDE  =   2_u32
  RULE_PAIR_FLAGS      =   4_u32
  RULE_LONE_RI_WIDE    =   8_u32
  RULE_VS16_WIDENS     =  16_u32
  RULE_VS15_NARROWS    =  32_u32
  RULE_MODIFIER_MERGES =  64_u32
  RULE_KEYCAP_WIDE     = 128_u32
  RULE_SPACING_WIDENS  = 256_u32

  VS15      =  0xFE0E_u32
  VS16      =  0xFE0F_u32
  ZWJ       =  0x200D_u32
  KEYCAP    =  0x20E3_u32
  RI_FIRST  = 0x1F1E6_u32
  RI_LAST   = 0x1F1FF_u32
  MOD_FIRST = 0x1F3FB_u32
  MOD_LAST  = 0x1F3FF_u32

  CATEGORY_AMBIGUOUS =    1_u32
  CATEGORY_LONE_RI   =    2_u32
  CATEGORY_FLAG      =    4_u32
  CATEGORY_ZWJ       =    8_u32
  CATEGORY_MODIFIER  =   16_u32
  CATEGORY_VS16      =   32_u32
  CATEGORY_VS15      =   64_u32
  CATEGORY_KEYCAP    =  128_u32
  CATEGORY_COMBINING =  256_u32
  CATEGORY_CONJUNCT  =  512_u32
  CATEGORY_JAMO      = 1024_u32

  def self.props(cp : UInt32) : UInt8
    Props.lookup(cp)
  end

  SWAR_HIGH = 0x8080808080808080_u64
  SWAR_SP   = 0x2020202020202020_u64
  SWAR_ONE  = 0x0101010101010101_u64
  SWAR_DEL  = 0x7F7F7F7F7F7F7F7F_u64

  def self.scan_printable(bytes : Bytes, from : Int32 = 0) : Int32
    raise IndexError.new unless from >= 0 && from <= bytes.size
    n   = bytes.size - from
    ptr = bytes.to_unsafe + from
    i   = 0
    while i + 8 <= n
      word = 0_u64
      Intrinsics.memcpy(pointerof(word).as(Void*), (ptr + i).as(Void*), 8, false)
      x = word ^ SWAR_DEL
      bad = (word & SWAR_HIGH) |
            ((word &- SWAR_SP) & ~word & SWAR_HIGH) |
            ((x &- SWAR_ONE) & ~x & SWAR_HIGH)
      break if bad != 0_u64
      i += 8
    end
    while i < n && printable?(ptr[i])
      i += 1
    end
    i
  end

  def self.segment(bytes : Bytes, from : Int32, rules : UInt32, dst : Slice(Cluster)) : Int32
    raise IndexError.new unless from >= 0 && from <= bytes.size
    n = bytes.size - from
    return 0 if n == 0 || dst.empty?

    clusters = rule?(rules, RULE_CLUSTERS)
    state    = ClusterState.new
    grapheme = Grapheme::State.new
    prev     = 0_u32
    count    = 0
    start    = 0
    i        = 0
    have     = false

    while i < n
      index = from + i
      b     = bytes.unsafe_fetch(index)
      cp, used = Utf8.decode(bytes, index)
      pair     = Props.pair(cp)
      prop     = pair.to_u8!
      w        = codepoint_width(cp, prop, rules)
      boundary = !have || (clusters ? cluster_break?(prev, cp, (pair >> 8).to_u8!, pointerof(grapheme), rules) : codepoint_break?(state, prev, cp, w, rules))

      if boundary && printable?(b)
        run_start = i
        if have
          if i - start == 1 && printable?(bytes.unsafe_fetch(from + start))
            run_start = start
          else
            count = emit(dst, count, start, i - start, state.width(rules), 0_u8)
            return count if count == dst.size
          end
        end

        j = i + scan_printable(bytes, from + i + 1)
        if j + 1 == n
          flags = n - run_start > 1 ? CLUSTER_ASCII_RUN : 0_u8
          return emit(dst, count, run_start, n - run_start, 1_u8, flags)
        end
        if j > run_start
          count = emit(dst, count, run_start, j - run_start, 1_u8, CLUSTER_ASCII_RUN)
          return count if count == dst.size
        end

        start    = j
        have     = true
        state    = ClusterState.ascii
        prev     = bytes.unsafe_fetch(from + j).to_u32
        grapheme = Grapheme::State.new
        i        = j + 1
        next
      end

      if boundary && have
        count = emit(dst, count, start, i - start, state.width(rules), 0_u8)
        return count if count == dst.size
        start = i
        state = ClusterState.new
      end

      state.absorb(cp, prop, w)
      have = true
      prev = cp
      i += used
    end

    have ? emit(dst, count, start, n - start, state.width(rules), 0_u8) : count
  end

  def self.classify(bytes : Bytes) : UInt32
    categories = 0_u32
    ri         = 0
    spacing    = 0
    zwj        = false
    after_zwj  = false
    base_pict  = false
    jamo       = false
    i          = 0

    while i < bytes.size
      cp, used = Utf8.decode(bytes, i)
      prop      = Props.lookup(cp)
      base_pict = Props.pictographic?(prop) if i == 0
      categories |= CATEGORY_AMBIGUOUS if Props.ambiguous?(prop)

      joined    = after_zwj
      after_zwj = false
      jamo      = true if jamo?(cp)
      if ri?(cp)
        ri += 1
      elsif modifier?(cp)
        categories |= CATEGORY_MODIFIER
      elsif cp == ZWJ
        zwj       = true
        after_zwj = true
      elsif cp == VS16
        categories |= CATEGORY_VS16
      elsif cp == VS15
        categories |= CATEGORY_VS15
      elsif cp == KEYCAP
        categories |= CATEGORY_KEYCAP
      elsif control?(cp)
      elsif Props.width(prop) == 0_u8
        categories |= CATEGORY_COMBINING
      elsif !joined
        spacing += 1
      end
      i += used
    end

    categories |= CATEGORY_LONE_RI if ri == 1
    categories |= CATEGORY_FLAG if ri >= 2
    categories |= CATEGORY_ZWJ if zwj && base_pict
    if spacing >= 2
      categories |= jamo ? CATEGORY_JAMO : CATEGORY_CONJUNCT
    end
    categories
  end

  def self.classify_cp(cp : UInt32) : UInt32
    return 0_u32 if cp >= 0x110000_u32
    categories = 0_u32
    prop       = Props.lookup(cp)
    categories |= CATEGORY_AMBIGUOUS if Props.ambiguous?(prop)
    if ri?(cp)
      categories |= CATEGORY_LONE_RI
    elsif modifier?(cp)
      categories |= CATEGORY_MODIFIER
    elsif cp == VS16
      categories |= CATEGORY_VS16
    elsif cp == VS15
      categories |= CATEGORY_VS15
    elsif cp == KEYCAP
      categories |= CATEGORY_KEYCAP
    elsif control?(cp)
    elsif Props.width(prop) == 0_u8
      categories |= CATEGORY_COMBINING
    end
    categories
  end

  private def self.emit(dst : Slice(Cluster), count : Int32, start : Int32, length : Int32,
                        width : UInt8, flags : UInt8) : Int32
    dst.unsafe_put(count, Cluster.new(start, length, width, flags))
    count + 1
  end

  private def self.codepoint_width(cp : UInt32, prop : UInt8, rules : UInt32) : UInt8
    w = Props.width(prop)
    w = 2_u8 if rule?(rules, RULE_AMBIGUOUS_WIDE) && Props.ambiguous?(prop)
    w = 0_u8 if !rule?(rules, RULE_CLUSTERS) && trailing_jamo?(cp)
    w
  end

  private def self.cluster_break?(prev : UInt32, cp : UInt32, cp_prop : UInt8, state : Grapheme::State*, rules : UInt32) : Bool
    return true if Grapheme.break?(prev, cp_prop, state)
    return !rule?(rules, RULE_PAIR_FLAGS) if ri?(cp)
    return !rule?(rules, RULE_MODIFIER_MERGES) if modifier?(cp)
    false
  end

  private def self.codepoint_break?(state : ClusterState, prev : UInt32, cp : UInt32,
                                    w : UInt8, rules : UInt32) : Bool
    return true if control?(cp) || control?(prev)
    return false if w == 0_u8
    return !(rule?(rules, RULE_PAIR_FLAGS) && state.ri == 1 && state.base_ri) if ri?(cp)
    return !(rule?(rules, RULE_MODIFIER_MERGES) && state.base_pict) if modifier?(cp)
    true
  end

  private def self.printable?(byte : UInt8) : Bool
    byte >= 0x20_u8 && byte < 0x7F_u8
  end

  private def self.rule?(rules : UInt32, rule : UInt32) : Bool
    (rules & rule) != 0_u32
  end

  private def self.in_range?(cp : UInt32, first : UInt32, last : UInt32) : Bool
    cp >= first && cp <= last
  end

  private def self.ri?(cp : UInt32) : Bool
    in_range?(cp, RI_FIRST, RI_LAST)
  end

  private def self.modifier?(cp : UInt32) : Bool
    in_range?(cp, MOD_FIRST, MOD_LAST)
  end

  private def self.control?(cp : UInt32) : Bool
    cp < 0x20_u32 || in_range?(cp, 0x7F_u32, 0x9F_u32)
  end

  private def self.jamo?(cp : UInt32) : Bool
    in_range?(cp, 0x1100_u32, 0x11FF_u32) ||
      in_range?(cp, 0xA960_u32, 0xA97F_u32) ||
      in_range?(cp, 0xD7B0_u32, 0xD7FF_u32)
  end

  private def self.trailing_jamo?(cp : UInt32) : Bool
    in_range?(cp, 0x1160_u32, 0x11FF_u32) || in_range?(cp, 0xD7B0_u32, 0xD7FF_u32)
  end
end
