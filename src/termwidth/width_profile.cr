# src/termwidth/width_profile.cr
require "./cluster"
require "./segmenter"

module TermWidth
  @[Flags]
  enum Rule : UInt32
    Clusters       =   1
    AmbiguousWide  =   2
    PairFlags      =   4
    LoneRiWide     =   8
    Vs16Widens     =  16
    Vs15Narrows    =  32
    ModifierMerges =  64
    KeycapWide     = 128
    SpacingWidens  = 256
  end

  @[Flags]
  enum Category : UInt16
    Ambiguous =    1
    LoneRi    =    2
    Flag      =    4
    Zwj       =    8
    Modifier  =   16
    Vs16      =   32
    Vs15      =   64
    Keycap    =  128
    Combining =  256
    Conjunct  =  512
    Jamo      = 1024
  end

  struct WidthProfile
    record Sample, text : String, width : Int32?, edge : Int32? = nil, lead : Int32? = nil do
      def consistent? : Bool
        ((e = edge).nil? || e == width) && ((l = lead).nil? || l == width)
      end

      def fixed_by_lead?(predicted : Int32) : Bool
        lead == predicted && ((e = edge).nil? || e == predicted) && width != predicted
      end
    end

    RULE_NAMES = {
      Rule::Clusters       => "clusters",
      Rule::AmbiguousWide  => "ambiguous-wide",
      Rule::PairFlags      => "pair-flags",
      Rule::LoneRiWide     => "lone-ri-wide",
      Rule::Vs16Widens     => "vs16-widens",
      Rule::Vs15Narrows    => "vs15-narrows",
      Rule::ModifierMerges => "modifier-merges",
      Rule::KeycapWide     => "keycap-wide",
      Rule::SpacingWidens  => "spacing-widens",
    }

    CATEGORY_NAMES = {
      Category::Ambiguous => "ambiguous",
      Category::LoneRi    => "lone-ri",
      Category::Flag      => "flag",
      Category::Zwj       => "zwj",
      Category::Modifier  => "modifier",
      Category::Vs16      => "vs16",
      Category::Vs15      => "vs15",
      Category::Keycap    => "keycap",
      Category::Combining => "combining",
      Category::Conjunct  => "conjunct",
      Category::Jamo      => "jamo",
    }

    CALIBRATION = [
      "x",
      "日",
      "¡",
      "\u{1F1F3}",
      "\u{1F1F3}\u{1F1F1}",
      "\u{1F1F3}\u{1F1F1}\u{1F1EF}\u{1F1F5}",
      "\u{1F468}‍\u{1F469}‍\u{1F467}",
      "\u{1F44D}\u{1F3FD}",
      "❤️",
      "⌚︎",
      "1️⃣",
      "e\u0301",
      "क्ष",
      "각",
    ]

    SANITY = {"x" => 1, "日" => 2}

    getter rules    : Rule
    getter volatile : Category
    getter lead_in  : Category

    def initialize(@rules : Rule, @volatile : Category = Category::None, @lead_in : Category = Category::None)
    end

    UNICODE      = new(Rule::Clusters | Rule::PairFlags | Rule::LoneRiWide | Rule::Vs16Widens | Rule::ModifierMerges | Rule::KeycapWide)
    UNICODE_WIDE = new(UNICODE.rules | Rule::AmbiguousWide)
    CAUTIOUS     = new(UNICODE.rules, Category::LoneRi | Category::Flag | Category::Zwj | Category::Modifier |
                                      Category::Vs16 | Category::Vs15 | Category::Keycap | Category::Conjunct |
                                      Category::Jamo)

    def self.categories(text : String) : Category
      acc = 0_u32
      Segmenter::NARROW.each(text) { |cluster, _| acc |= TermWidth.classify(cluster) }
      Category.new(acc.to_u16)
    end

    def self.infer(samples : Enumerable(Sample)) : WidthProfile
      return CAUTIOUS unless samples.all? { |s| (want = SANITY[s.text]?).nil? || (s.width == want && s.consistent?) }

      best       = UNICODE.rules
      best_score = {Int32::MAX, Int32::MAX, UInt32::MAX}
      (0_u32..Rule::All.value).each do |bits|
        rules     = Rule.new(bits)
        segmenter = Segmenter.new(new(rules))
        misses    = samples.count { |s| (w = s.width) && s.consistent? && segmenter.measure(s.text) != w }
        score = {misses, (bits ^ UNICODE.rules.value).popcount, bits}
        if (score <=> best_score) < 0
          best       = rules
          best_score = score
        end
      end

      segmenter = Segmenter.new(new(best))
      cleared   = Category::None
      failed    = [] of Category
      led       = [] of Category
      samples.each do |s|
        w         = s.width
        predicted = segmenter.measure(s.text)
        if w && s.consistent? && predicted == w
          cleared |= categories(s.text)
        elsif w && s.fixed_by_lead?(predicted)
          led << categories(s.text)
        else
          failed << categories(s.text)
        end
      end
      volatile = blame(failed, cleared)
      lead_in  = Category.new(blame(led, cleared).value & ~volatile.value)
      new(best, volatile, lead_in)
    end

    private def self.blame(groups : Array(Category), cleared : Category) : Category
      groups.reduce(Category::None) do |acc, cats|
        blamed = Category.new(cats.value & ~cleared.value)
        acc | (blamed.none? ? cats : blamed)
      end
    end

    def wide_ambiguous? : Bool
      @rules.ambiguous_wide?
    end

    def clusters? : Bool
      @rules.clusters?
    end

    def volatile?(categories : Category) : Bool
      (@volatile.value & categories.value) != 0_u16
    end

    def lead_in?(categories : Category) : Bool
      (@lead_in.value & categories.value) != 0_u16
    end

    def shaped? : Bool
      !@volatile.none? || !@lead_in.none?
    end

    def rule_names : String
      names(RULE_NAMES, @rules)
    end

    def volatile_names : String
      names(CATEGORY_NAMES, @volatile)
    end

    def lead_in_names : String
      names(CATEGORY_NAMES, @lead_in)
    end

    def to_s(io : IO) : Nil
      io << "rules=" << rule_names << " volatile=" << volatile_names << " lead-in=" << lead_in_names
    end

    private def names(table : Hash(T, String), flags : T) : String forall T
      picked = table.compact_map { |flag, name| flags.includes?(flag) ? name : nil }
      picked.empty? ? "none" : picked.join(',')
    end
  end
end
