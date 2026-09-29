# tool/gen_unicode.cr

module Gen
  VERSION = "17.0.0"
  MAX     = 0x110000

  UCD = "#{__DIR__}/ucd"
  OUT = "#{__DIR__}/../src/termwidth"

  WIDTH_MASK       = 0x03
  AMBIGUOUS_BIT    = 0x04
  PICTOGRAPHIC_BIT = 0x08
  DEFAULT_PROP     = 0x01

  GRAPHEME_OTHER                  =  0_u8
  GRAPHEME_BOTH_EXTEND_ICB_EXTEND =  1_u8
  GRAPHEME_BOTH_EXTEND_ICB_LINKER =  2_u8
  GRAPHEME_BOTH_ZWJ_ICB_EXTEND    =  3_u8
  GRAPHEME_CONTROL                =  4_u8
  GRAPHEME_CR                     =  5_u8
  GRAPHEME_EXTEND                 =  6_u8
  GRAPHEME_EXTENDED_PICTOGRAPHIC  =  7_u8
  GRAPHEME_HANGUL_L               =  8_u8
  GRAPHEME_HANGUL_V               =  9_u8
  GRAPHEME_HANGUL_T               = 10_u8
  GRAPHEME_HANGUL_LV              = 11_u8
  GRAPHEME_HANGUL_LVT             = 12_u8
  GRAPHEME_ICB_CONSONANT          = 13_u8
  GRAPHEME_ICB_EXTEND             = 14_u8
  GRAPHEME_ICB_LINKER             = 15_u8
  GRAPHEME_LF                     = 16_u8
  GRAPHEME_PREPEND                = 17_u8
  GRAPHEME_REGIONAL_INDICATOR     = 18_u8
  GRAPHEME_SPACING_MARK           = 19_u8
  GRAPHEME_ZWJ                    = 20_u8

  ICB_NONE      = 0_u8
  ICB_CONSONANT = 1_u8
  ICB_EXTEND    = 2_u8
  ICB_LINKER    = 3_u8

  ZERO_WIDTH_CATEGORIES = {"Cc", "Cf", "Cs", "Mn", "Me", "Zl", "Zp"}

  EAW_DEFAULT_WIDE = [
    {0x3400,  0x4DBF},
    {0x4E00,  0x9FFF},
    {0xF900,  0xFAFF},
    {0x20000, 0x2FFFD},
    {0x30000, 0x3FFFD},
  ]

  GRAPHEME_NAMES = {
    "Control"            => GRAPHEME_CONTROL,
    "CR"                 => GRAPHEME_CR,
    "Extend"             => GRAPHEME_EXTEND,
    "L"                  => GRAPHEME_HANGUL_L,
    "V"                  => GRAPHEME_HANGUL_V,
    "T"                  => GRAPHEME_HANGUL_T,
    "LV"                 => GRAPHEME_HANGUL_LV,
    "LVT"                => GRAPHEME_HANGUL_LVT,
    "LF"                 => GRAPHEME_LF,
    "Prepend"            => GRAPHEME_PREPEND,
    "Regional_Indicator" => GRAPHEME_REGIONAL_INDICATOR,
    "SpacingMark"        => GRAPHEME_SPACING_MARK,
    "ZWJ"                => GRAPHEME_ZWJ,
  }

  class Build
    getter pict     : Slice(Bool)
    getter epres    : Slice(Bool)
    getter eaw      : Slice(UInt8)
    getter category : Array(String)
    getter prop     : Slice(UInt8)
    getter grapheme : Slice(UInt8)

    EAW_N = 0_u8
    EAW_A = 1_u8
    EAW_W = 2_u8

    def initialize
      @pict     = Slice(Bool).new(MAX, false)
      @epres    = Slice(Bool).new(MAX, false)
      @eaw      = Slice(UInt8).new(MAX, EAW_N)
      @category = Array(String).new(MAX, "Cn")
      @prop     = Slice(UInt8).new(MAX, 0_u8)
      @grapheme = Slice(UInt8).new(MAX, GRAPHEME_OTHER)
    end

    def run : Nil
      load_grapheme
      load_emoji
      load_indic
      load_eaw
      load_category
      assign_width_props
    end

    private def each_range(file : String, & : Int32, Int32, Array(String) ->) : Nil
      File.each_line(File.join(UCD, file)) do |line|
        body = line.split('#', 2)[0].strip
        next if body.empty?
        fields = body.split(';').map(&.strip)
        span   = fields[0]
        if idx = span.index("..")
          yield span[0, idx].to_i(16), span[idx + 2..].to_i(16), fields
        else
          cp = span.to_i(16)
          yield cp, cp, fields
        end
      end
    end

    private def load_grapheme : Nil
      each_range("GraphemeBreakProperty.txt") do |lo, hi, fields|
        value = GRAPHEME_NAMES[fields[1]]?
        next unless value
        (lo..hi).each do |cp|
          current = @grapheme[cp]
          raise "grapheme property conflict at U+#{cp.to_s(16)}" unless current == GRAPHEME_OTHER || current == value
          @grapheme[cp] = value
        end
      end
    end

    private def load_emoji : Nil
      each_range("emoji-data.txt") do |lo, hi, fields|
        case fields[1]
        when "Extended_Pictographic"
          (lo..hi).each do |cp|
            @pict[cp] = true
            current = @grapheme[cp]
            raise "extended pictographic conflict at U+#{cp.to_s(16)}" unless current == GRAPHEME_OTHER
            @grapheme[cp] = GRAPHEME_EXTENDED_PICTOGRAPHIC
          end
        when "Emoji_Presentation"
          (lo..hi).each { |cp| @epres[cp] = true }
        end
      end
    end

    private def load_indic : Nil
      each_range("DerivedCoreProperties.txt") do |lo, hi, fields|
        next unless fields[1]? == "InCB" && fields.size >= 3
        kind = case fields[2]
               when "Consonant" then ICB_CONSONANT
               when "Extend"    then ICB_EXTEND
               when "Linker"    then ICB_LINKER
               else                  ICB_NONE
               end
        next if kind == ICB_NONE
        (lo..hi).each { |cp| combine_indic(cp, kind) }
      end
    end

    private def combine_indic(cp : Int32, kind : UInt8) : Nil
      current = @grapheme[cp]
      combined = if kind == ICB_CONSONANT
                   raise "indic consonant conflict at U+#{cp.to_s(16)}" unless current == GRAPHEME_OTHER
                   GRAPHEME_ICB_CONSONANT
                 elsif current == GRAPHEME_OTHER
                   kind == ICB_EXTEND ? GRAPHEME_ICB_EXTEND : GRAPHEME_ICB_LINKER
                 elsif current == GRAPHEME_EXTEND && kind == ICB_EXTEND
                   GRAPHEME_BOTH_EXTEND_ICB_EXTEND
                 elsif current == GRAPHEME_EXTEND && kind == ICB_LINKER
                   GRAPHEME_BOTH_EXTEND_ICB_LINKER
                 elsif current == GRAPHEME_ZWJ && kind == ICB_EXTEND
                   GRAPHEME_BOTH_ZWJ_ICB_EXTEND
                 else
                   raise "indic property conflict at U+#{cp.to_s(16)}"
                 end
      @grapheme[cp] = combined
    end

    private def load_eaw : Nil
      EAW_DEFAULT_WIDE.each do |span|
        (span[0]..span[1]).each { |cp| @eaw[cp] = EAW_W }
      end
      each_range("EastAsianWidth.txt") do |lo, hi, fields|
        value = case fields[1]
                when "W", "F" then EAW_W
                when "A"      then EAW_A
                else               EAW_N
                end
        (lo..hi).each { |cp| @eaw[cp] = value }
      end
    end

    private def load_category : Nil
      pending = nil.as(Tuple(Int32, String)?)
      File.each_line(File.join(UCD, "UnicodeData.txt")) do |line|
        fields = line.chomp.split(';')
        cp     = fields[0].to_i(16)
        name   = fields[1]
        cat    = fields[2]
        if name.ends_with?(", First>")
          pending = {cp, cat}
        elsif name.ends_with?(", Last>")
          range = pending.not_nil!
          (range[0]..cp).each { |code| @category[code] = range[1] }
          pending = nil
        else
          @category[cp] = cat
        end
      end
      raise "unclosed UnicodeData range" unless pending.nil?
    end

    private def assign_width_props : Nil
      cp = 0
      while cp < MAX
        amb = false
        width = if ZERO_WIDTH_CATEGORIES.includes?(@category[cp])
                  0
                elsif @epres[cp]
                  2
                else
                  case @eaw[cp]
                  when EAW_W then 2
                  when EAW_A then amb = true; 1
                  else            1
                  end
                end
        @prop[cp] = (width | (amb ? AMBIGUOUS_BIT : 0) | (@pict[cp] ? PICTOGRAPHIC_BIT : 0)).to_u8
        cp += 1
      end
    end
  end

  class Trie(T)
    getter shift1 : Int32
    getter shift2 : Int32
    getter stage1 : Array(Int32)
    getter stage2 : Array(Int32)
    getter stage3 : Array(T)

    def initialize(@shift1 : Int32, @shift2 : Int32, @stage1 : Array(Int32),
                   @stage2 : Array(Int32), @stage3 : Array(T))
    end

    def bytes : Int32
      @stage1.size * 2 + @stage2.size * 2 + @stage3.size * sizeof(T)
    end

    def self.build(prop : Slice(T), shift1 : Int32, shift2 : Int32) : Trie(T)
      leaf  = 1 << shift2
      mid   = 1 << (shift1 - shift2)
      total = ((MAX + (1 << shift1) - 1) >> shift1) << shift1

      stage3     = [] of T
      leaf_index = {} of Array(T) => Int32
      mid_blocks = [] of Array(Int32)

      cp = 0
      while cp < total
        block = Array(Int32).new(mid, 0)
        m     = 0
        while m < mid
          base = cp + m * leaf
          key  = Array(T).new(leaf) { |i| base + i < MAX ? prop[base + i] : T.zero }
          slot = leaf_index[key]?
          unless slot
            slot = stage3.size // leaf
            leaf_index[key] = slot
            stage3.concat(key)
          end
          block[m] = slot
          m += 1
        end
        mid_blocks << block
        cp += 1 << shift1
      end

      stage2    = [] of Int32
      mid_index = {} of Array(Int32) => Int32
      stage1    = Array(Int32).new(mid_blocks.size, 0)

      mid_blocks.each_with_index do |block, i|
        slot = mid_index[block]?
        unless slot
          slot = stage2.size // mid
          mid_index[block] = slot
          stage2.concat(block)
        end
        stage1[i] = slot
      end

      new(shift1, shift2, stage1, stage2, stage3)
    end

    def self.optimal(prop : Slice(T)) : Trie(T)
      best = nil.as(Trie(T)?)
      (9..16).each do |s1|
        (4..(s1 - 1)).each do |s2|
          next if s1 - s2 > 10
          candidate = build(prop, s1, s2)
          best      = candidate if best.nil? || candidate.bytes < best.bytes
        end
      end
      best.not_nil!
    end
  end

  def self.emit(build : Build, trie : Trie(UInt16)) : Nil
    Dir.mkdir_p(OUT)

    ascii = Array(UInt16).new(128) { |cp| fuse(build.prop[cp], build.grapheme[cp]) }
    bytes = trie.bytes + ascii.size * 2

    raise "trie stage2 index exceeds uint16" if trie.stage1.max > UInt16::MAX
    raise "trie stage3 index exceeds uint16" if trie.stage2.max > UInt16::MAX

    source = String.build do |sb|
      sb << "# src/termwidth/tables.cr\n"
      sb << "module TermWidth::Tables\n"
      sb << "  UNICODE_VERSION = #{VERSION.inspect}\n\n"

      sb << "  WIDTH_MASK = #{hex(WIDTH_MASK, 2)}_u8\n"
      sb << "  AMBIGUOUS_BIT = #{hex(AMBIGUOUS_BIT, 2)}_u8\n"
      sb << "  PICTOGRAPHIC_BIT = #{hex(PICTOGRAPHIC_BIT, 2)}_u8\n"
      sb << "  DEFAULT_PROP = #{hex(DEFAULT_PROP, 2)}_u8\n"
      sb << "  DEFAULT_PAIR = #{hex(fuse(DEFAULT_PROP, GRAPHEME_OTHER).to_i, 4)}_u16\n\n"

      sb << "  GRAPHEME_OTHER = #{GRAPHEME_OTHER}_u8\n"
      sb << "  GRAPHEME_BOTH_EXTEND_ICB_EXTEND = #{GRAPHEME_BOTH_EXTEND_ICB_EXTEND}_u8\n"
      sb << "  GRAPHEME_BOTH_EXTEND_ICB_LINKER = #{GRAPHEME_BOTH_EXTEND_ICB_LINKER}_u8\n"
      sb << "  GRAPHEME_BOTH_ZWJ_ICB_EXTEND = #{GRAPHEME_BOTH_ZWJ_ICB_EXTEND}_u8\n"
      sb << "  GRAPHEME_CONTROL = #{GRAPHEME_CONTROL}_u8\n"
      sb << "  GRAPHEME_CR = #{GRAPHEME_CR}_u8\n"
      sb << "  GRAPHEME_EXTEND = #{GRAPHEME_EXTEND}_u8\n"
      sb << "  GRAPHEME_EXTENDED_PICTOGRAPHIC = #{GRAPHEME_EXTENDED_PICTOGRAPHIC}_u8\n"
      sb << "  GRAPHEME_HANGUL_L = #{GRAPHEME_HANGUL_L}_u8\n"
      sb << "  GRAPHEME_HANGUL_V = #{GRAPHEME_HANGUL_V}_u8\n"
      sb << "  GRAPHEME_HANGUL_T = #{GRAPHEME_HANGUL_T}_u8\n"
      sb << "  GRAPHEME_HANGUL_LV = #{GRAPHEME_HANGUL_LV}_u8\n"
      sb << "  GRAPHEME_HANGUL_LVT = #{GRAPHEME_HANGUL_LVT}_u8\n"
      sb << "  GRAPHEME_ICB_CONSONANT = #{GRAPHEME_ICB_CONSONANT}_u8\n"
      sb << "  GRAPHEME_ICB_EXTEND = #{GRAPHEME_ICB_EXTEND}_u8\n"
      sb << "  GRAPHEME_ICB_LINKER = #{GRAPHEME_ICB_LINKER}_u8\n"
      sb << "  GRAPHEME_LF = #{GRAPHEME_LF}_u8\n"
      sb << "  GRAPHEME_PREPEND = #{GRAPHEME_PREPEND}_u8\n"
      sb << "  GRAPHEME_REGIONAL_INDICATOR = #{GRAPHEME_REGIONAL_INDICATOR}_u8\n"
      sb << "  GRAPHEME_SPACING_MARK = #{GRAPHEME_SPACING_MARK}_u8\n"
      sb << "  GRAPHEME_ZWJ = #{GRAPHEME_ZWJ}_u8\n\n"

      emit_trie_constants(sb, trie, ascii, bytes)
      emit_lookups(sb)
      sb << "end\n"
    end

    File.write(File.join(OUT, "tables.cr"), source)

    STDOUT.puts "unicode          #{VERSION}"
    STDOUT.puts "shifts           #{trie.shift1}/#{trie.shift2}"
    STDOUT.puts "tables           #{bytes} B"
  end

  private def self.fuse(prop : Int32, grapheme : UInt8) : UInt16
    (prop | (grapheme.to_i << 8)).to_u16
  end

  private def self.emit_trie_constants(sb : String::Builder, trie : Trie(UInt16),
                                       ascii : Array(UInt16), total : Int32) : Nil
    sb << "  PROP_SHIFT1 = #{trie.shift1}\n"
    sb << "  PROP_SHIFT2 = #{trie.shift2}\n"
    sb << "  PROP_SPAN1 = #{trie.shift1 - trie.shift2}\n"
    sb << "  PROP_MASK1 = #{(1 << (trie.shift1 - trie.shift2)) - 1}\n"
    sb << "  PROP_MASK2 = #{(1 << trie.shift2) - 1}\n"
    sb << "  PROP_LIMIT = #{trie.stage1.size << trie.shift1}_u32\n"
    sb << "  PROP_STAGE1_COUNT = #{trie.stage1.size}\n"
    sb << "  PROP_STAGE2_COUNT = #{trie.stage2.size}\n"
    sb << "  PROP_STAGE3_COUNT = #{trie.stage3.size}\n"
    sb << "  PROP_ASCII_COUNT = #{ascii.size}\n"
    sb << "  PROP_TABLE_BYTES = #{total}\n\n"

    crystal_array(sb, "PROP_STAGE1", trie.stage1, 2, 12)
    crystal_array(sb, "PROP_STAGE2", trie.stage2, 2, 12)
    crystal_array(sb, "PROP_STAGE3", trie.stage3, 2, 12)
    crystal_array(sb, "PROP_ASCII", ascii, 2, 12)
  end

  private def self.emit_lookups(sb : String::Builder) : Nil
    sb << "  def self.prop_pair(cp : UInt32) : UInt16\n"
    sb << "    return PROP_ASCII[cp.to_i] if cp < 0x80_u32\n"
    sb << "    return DEFAULT_PAIR if cp >= PROP_LIMIT\n"
    sb << "    stage1 = PROP_STAGE1[(cp >> PROP_SHIFT1).to_i].to_i\n"
    sb << "    stage2 = PROP_STAGE2[((stage1 << PROP_SPAN1) | ((cp >> PROP_SHIFT2).to_i & PROP_MASK1))]\n"
    sb << "    PROP_STAGE3[((stage2.to_i << PROP_SHIFT2) | (cp.to_i & PROP_MASK2))]\n"
    sb << "  end\n\n"
    sb << "  def self.width_prop(cp : UInt32) : UInt8\n"
    sb << "    prop_pair(cp).to_u8!\n"
    sb << "  end\n\n"
    sb << "  def self.grapheme_prop(cp : UInt32) : UInt8\n"
    sb << "    (prop_pair(cp) >> 8).to_u8!\n"
    sb << "  end\n"
  end

  private def self.crystal_array(sb : String::Builder, name : String,
                                 values : Array(Int32) | Array(UInt8) | Array(UInt16), width : Int32, row : Int32) : Nil
    type = width == 2 ? "UInt16" : "UInt8"
    sb << "  " << name << " = Slice(" << type << ").literal(\n"
    values.each_slice(row) do |slice|
      sb << "    "
      slice.each { |v| sb << hex(v.to_i, width * 2) << ", " }
      sb << "\n"
    end
    sb << "  )\n\n"
  end

  private def self.hex(value : Int32, width : Int32) : String
    "0x#{value.to_s(16).rjust(width, '0')}"
  end

  def self.run : Nil
    build = Build.new
    build.run
    fused = Slice(UInt16).new(MAX) { |cp| fuse(build.prop[cp], build.grapheme[cp]) }
    emit(build, Trie(UInt16).optimal(fused))
  end
end

Gen.run
