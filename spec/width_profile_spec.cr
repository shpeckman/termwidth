# spec/width_profile_spec.cr

require "./spec_helper"

private alias Rule = TermWidth::Rule
private alias Category = TermWidth::Category
private alias WidthProfile = TermWidth::WidthProfile

private FAMILY   = "\u{1F468}‍\u{1F469}‍\u{1F467}"
private FLAG     = "\u{1F1F3}\u{1F1F1}"
private THUMB    = "\u{1F44D}\u{1F3FD}"
private HEART    = "❤️"
private WATCH    = "⌚︎"
private KEYCAP   = "1️⃣"
private CONJUNCT = "क्ष"
private JAMO     = "각"

private def segmenter(rules : Rule) : TermWidth::Segmenter
  TermWidth::Segmenter.new(WidthProfile.new(rules))
end

private def measure(rules : Rule, text : String) : Int32
  segmenter(rules).measure(text)
end

private def samples(rules : Rule) : Array(WidthProfile::Sample)
  seg = segmenter(rules)
  WidthProfile::CALIBRATION.map { |text| WidthProfile::Sample.new(text, seg.measure(text)) }
end

private def replace(list : Array(WidthProfile::Sample), text : String, width : Int32?) : Array(WidthProfile::Sample)
  list.map { |s| s.text == text ? WidthProfile::Sample.new(text, width) : s }
end

describe TermWidth::WidthProfile do
  it "keeps the unicode profile's widths for the calibration samples" do
    WidthProfile::CALIBRATION.map { |t| TermWidth::Segmenter::NARROW.measure(t) }
      .should eq([1, 2, 1, 2, 2, 4, 2, 2, 2, 2, 2, 1, 1, 2])
  end

  it "splits sequences into codepoints without the cluster rule" do
    rules = Rule::None
    measure(rules, FAMILY).should eq(6)
    measure(rules, FLAG).should eq(2)
    measure(rules, THUMB).should eq(4)
    measure(rules, HEART).should eq(1)
    measure(rules, KEYCAP).should eq(1)
    measure(rules, CONJUNCT).should eq(2)
    measure(rules, JAMO).should eq(2)
    measure(rules, WATCH).should eq(2)
    clusters(FAMILY, segmenter(rules)).map(&.[0]).should eq(["\u{1F468}‍", "\u{1F469}‍", "\u{1F467}"])
  end

  it "keeps controls apart in codepoint mode" do
    clusters("á\ń", segmenter(Rule::None)).map(&.[0]).should eq(["á", "\n", "́"])
  end

  it "pairs flags and merges modifiers in codepoint mode when the rules say so" do
    rules = Rule::PairFlags | Rule::ModifierMerges
    widths("\u{1F1F3}\u{1F1F1}\u{1F1EF}", segmenter(rules)).should eq([2_u8, 1_u8])
    widths(THUMB, segmenter(rules)).should eq([2_u8])
    widths("a\u{1F3FD}", segmenter(rules)).should eq([1_u8, 2_u8])
  end

  it "applies each rule to grapheme clusters" do
    base = WidthProfile::UNICODE.rules
    measure(base & ~Rule::PairFlags, FLAG).should eq(4)
    measure(base & ~Rule::PairFlags & ~Rule::LoneRiWide, FLAG).should eq(2)
    measure(base & ~Rule::LoneRiWide, "\u{1F1F3}").should eq(1)
    measure(base & ~Rule::ModifierMerges, THUMB).should eq(4)
    measure(base & ~Rule::Vs16Widens, HEART).should eq(1)
    measure(base | Rule::Vs15Narrows, WATCH).should eq(1)
    measure(base & ~Rule::KeycapWide, KEYCAP).should eq(1)
    measure(base | Rule::AmbiguousWide, "¡").should eq(2)
  end

  it "widens a cluster with several spacing codepoints when told to" do
    rules = WidthProfile::UNICODE.rules | Rule::SpacingWidens
    measure(rules, CONJUNCT).should eq(2)
    measure(rules, "\u0915\u094D\u0937\u0924\u094D\u0930\u093F\u092F").should eq(5)
    measure(rules, JAMO).should eq(2)
    measure(rules, "e\u0301").should eq(1)
    measure(rules, FAMILY).should eq(2)
    measure(rules, FLAG).should eq(2)
  end

  it "classifies the calibration samples" do
    WidthProfile::CALIBRATION.map { |t| WidthProfile.categories(t) }.should eq([
      Category::None, Category::None, Category::Ambiguous, Category::LoneRi, Category::Flag, Category::Flag,
      Category::Zwj, Category::Modifier, Category::Vs16, Category::Vs15, Category::Vs16 | Category::Keycap,
      Category::Combining, Category::Conjunct | Category::Combining, Category::Jamo,
    ])
  end

  it "infers the unicode profile from a terminal that agrees with it" do
    WidthProfile.infer(samples(WidthProfile::UNICODE.rules)).should eq(WidthProfile::UNICODE)
  end

  it "infers a profile that reproduces every consistent terminal" do
    rng = Random.new(17)
    ([Rule::None, Rule::Clusters, Rule::All, WidthProfile::UNICODE_WIDE.rules] +
      Array.new(24) { Rule.new(rng.rand(0_u32..Rule::All.value)) }).each do |truth|
      measured = samples(truth)
      profile  = WidthProfile.infer(measured)
      profile.volatile.should eq(Category::None)
      seg = TermWidth::Segmenter.new(profile)
      measured.each { |s| seg.measure(s.text).should eq(s.width) }
    end
  end

  it "picks the ambiguous width from the ambiguous sample" do
    profile = WidthProfile.infer(replace(samples(WidthProfile::UNICODE.rules), "¡", 2))
    profile.rules.should eq(WidthProfile::UNICODE_WIDE.rules)
    profile.volatile.should eq(Category::None)
  end

  it "marks a flag run that no rule explains as volatile" do
    run     = "\u{1F1F3}\u{1F1F1}\u{1F1EF}\u{1F1F5}"
    profile = WidthProfile.infer(replace(samples(WidthProfile::UNICODE.rules), run, 5))
    profile.rules.should eq(WidthProfile::UNICODE.rules)
    profile.volatile.should eq(Category::Flag)
  end

  it "marks samples whose width depends on the column as volatile" do
    run      = "\u{1F1F3}\u{1F1F1}\u{1F1EF}\u{1F1F5}"
    measured = samples(WidthProfile::UNICODE.rules).map { |s| s.text == run ? WidthProfile::Sample.new(run, 4, 3) : s }
    profile  = WidthProfile.infer(measured)
    profile.rules.should eq(WidthProfile::UNICODE.rules)
    profile.volatile.should eq(Category::Flag)
  end

  it "keeps position-dependent samples out of the rule choice" do
    measured = samples(WidthProfile::UNICODE.rules).map do |s|
      flags = WidthProfile.categories(s.text).includes?(Category::Flag) || WidthProfile.categories(s.text).includes?(Category::LoneRi)
      flags ? WidthProfile::Sample.new(s.text, s.width.not_nil! + 2, s.width) : s
    end
    profile = WidthProfile.infer(measured)
    profile.rules.should eq(WidthProfile::UNICODE.rules)
    profile.volatile.should eq(Category::Flag | Category::LoneRi)
  end

  it "gives a lead-in to samples that a preceding character fixes" do
    measured = samples(WidthProfile::UNICODE.rules).map do |s|
      w     = s.width.not_nil!
      flags = WidthProfile.categories(s.text).includes?(Category::Flag)
      WidthProfile::Sample.new(s.text, flags ? w + 2 : w, w, w)
    end
    profile = WidthProfile.infer(measured)
    profile.rules.should eq(WidthProfile::UNICODE.rules)
    profile.volatile.should eq(Category::None)
    profile.lead_in.should eq(Category::Flag)
  end

  it "rejects sanity samples that move with the column" do
    measured = samples(WidthProfile::UNICODE.rules).map { |s| s.text == "日" ? WidthProfile::Sample.new("日", 2, 1) : s }
    WidthProfile.infer(measured).should eq(WidthProfile::CAUTIOUS)
  end

  it "infers summed conjunct widths" do
    profile = WidthProfile.infer(replace(samples(WidthProfile::UNICODE.rules), CONJUNCT, 2))
    profile.rules.should eq(WidthProfile::UNICODE.rules | Rule::SpacingWidens)
    profile.volatile.should eq(Category::None)
  end

  it "blames only the categories that no correct sample clears" do
    profile = WidthProfile.infer(replace(samples(WidthProfile::UNICODE.rules), CONJUNCT, 3))
    profile.volatile.should eq(Category::Conjunct)
    profile = WidthProfile.infer(replace(samples(WidthProfile::UNICODE.rules), KEYCAP, 3))
    profile.volatile.should eq(Category::Keycap)
  end

  it "marks unmeasured samples as volatile" do
    profile = WidthProfile.infer(replace(samples(WidthProfile::UNICODE.rules), FAMILY, nil))
    profile.volatile.should eq(Category::Zwj)
  end

  it "falls back to the cautious profile when the sanity samples fail" do
    WidthProfile.infer(replace(samples(WidthProfile::UNICODE.rules), "日", 1)).should eq(WidthProfile::CAUTIOUS)
    WidthProfile.infer(WidthProfile::CALIBRATION.map { |t| WidthProfile::Sample.new(t, nil) }).should eq(WidthProfile::CAUTIOUS)
  end

  it "names its rules and volatile categories" do
    WidthProfile::UNICODE.rule_names.should eq("clusters,pair-flags,lone-ri-wide,vs16-widens,modifier-merges,keycap-wide")
    WidthProfile::UNICODE.volatile_names.should eq("none")
    WidthProfile.new(Rule::None, Category::Flag | Category::Zwj).to_s.should eq("rules=none volatile=flag,zwj lead-in=none")
    WidthProfile.new(Rule::Clusters, Category::None, Category::Flag).lead_in_names.should eq("flag")
  end
end
