# src/termwidth/grapheme.cr
require "./tables"

module TermWidth::Grapheme
  struct State
    property prop       : UInt8
    property prop_set   : Bool
    property gb11       : Bool
    property gb12_13    : Bool
    property gb9c_level : UInt8

    def initialize
      @prop       = Tables::GRAPHEME_OTHER
      @prop_set   = false
      @gb11       = false
      @gb12_13    = false
      @gb9c_level = 0_u8
    end
  end

  def self.break?(prev : UInt32, cp : UInt32, state : State*) : Bool
    break?(prev, Tables.grapheme_prop(cp), state)
  end

  @[AlwaysInline]
  def self.break?(prev : UInt32, cp_prop : UInt8, state : State*) : Bool
    current = state.value

    if current.prop_set && current.prop == Tables::GRAPHEME_OTHER
      if cp_prop == Tables::GRAPHEME_OTHER
        current.gb9c_level = 0_u8
        state.value = current
        return true
      end
      if extend?(cp_prop) || cp_prop == Tables::GRAPHEME_SPACING_MARK
        current.prop = cp_prop
        current.gb9c_level = 0_u8
        state.value = current
        return false
      end
    end

    prev_prop = current.prop_set ? current.prop : property(prev)

    current.prop = cp_prop
    current.prop_set = true
    current.gb11 = update_gb11(prev_prop, current.gb11, cp_prop)
    current.gb12_13 = update_gb12_13(prev_prop, current.gb12_13, cp_prop)
    current.gb9c_level = update_gb9c(prev_prop, current.gb9c_level)

    not_break = base_no_break?(prev_prop, cp_prop) ||
                (current.gb9c_level == 3_u8 && cp_prop == Tables::GRAPHEME_ICB_CONSONANT) ||
                (current.gb11 && zwj?(prev_prop) && cp_prop == Tables::GRAPHEME_EXTENDED_PICTOGRAPHIC) ||
                current.gb12_13

    unless not_break
      current.gb11 = false
      current.gb12_13 = false
    end

    state.value = current
    !not_break
  end

  def self.property(cp : UInt32) : UInt8
    Tables.grapheme_prop(cp)
  end

  private def self.base_no_break?(prev : UInt8, cp : UInt8) : Bool
    return true if prev == Tables::GRAPHEME_CR && cp == Tables::GRAPHEME_LF
    return false if control?(prev) || control?(cp)
    return true if extend?(cp) || cp == Tables::GRAPHEME_SPACING_MARK
    return true if prev == Tables::GRAPHEME_PREPEND

    case prev
    when Tables::GRAPHEME_HANGUL_L
      cp == Tables::GRAPHEME_HANGUL_L || cp == Tables::GRAPHEME_HANGUL_V ||
        cp == Tables::GRAPHEME_HANGUL_LV || cp == Tables::GRAPHEME_HANGUL_LVT
    when Tables::GRAPHEME_HANGUL_V, Tables::GRAPHEME_HANGUL_LV
      cp == Tables::GRAPHEME_HANGUL_V || cp == Tables::GRAPHEME_HANGUL_T
    when Tables::GRAPHEME_HANGUL_T, Tables::GRAPHEME_HANGUL_LVT
      cp == Tables::GRAPHEME_HANGUL_T
    else
      false
    end
  end

  private def self.update_gb11(prev : UInt8, active : Bool, cp : UInt8) : Bool
    if prev == Tables::GRAPHEME_EXTENDED_PICTOGRAPHIC
      gb11_continuation?(cp)
    elsif !active
      false
    elsif zwj?(prev)
      cp == Tables::GRAPHEME_EXTENDED_PICTOGRAPHIC
    elsif gb11_extend?(prev)
      gb11_continuation?(cp)
    else
      false
    end
  end

  private def self.gb11_continuation?(prop : UInt8) : Bool
    zwj?(prop) || gb11_extend?(prop)
  end

  private def self.gb11_extend?(prop : UInt8) : Bool
    prop == Tables::GRAPHEME_EXTEND ||
      prop == Tables::GRAPHEME_BOTH_EXTEND_ICB_EXTEND ||
      prop == Tables::GRAPHEME_BOTH_EXTEND_ICB_LINKER
  end

  private def self.update_gb12_13(prev : UInt8, active : Bool, cp : UInt8) : Bool
    !active && prev == Tables::GRAPHEME_REGIONAL_INDICATOR && cp == Tables::GRAPHEME_REGIONAL_INDICATOR
  end

  private def self.update_gb9c(prev : UInt8, level : UInt8) : UInt8
    if level == 0_u8 && prev == Tables::GRAPHEME_ICB_CONSONANT
      1_u8
    elsif (level == 1_u8 || level == 2_u8) && icb_extend?(prev)
      2_u8
    elsif (level == 1_u8 || level == 2_u8) && icb_linker?(prev)
      3_u8
    elsif level == 3_u8 && (icb_extend?(prev) || icb_linker?(prev))
      3_u8
    elsif prev == Tables::GRAPHEME_ICB_CONSONANT
      1_u8
    else
      0_u8
    end
  end

  private def self.control?(prop : UInt8) : Bool
    prop == Tables::GRAPHEME_CONTROL || prop == Tables::GRAPHEME_CR || prop == Tables::GRAPHEME_LF
  end

  private def self.extend?(prop : UInt8) : Bool
    prop == Tables::GRAPHEME_EXTEND ||
      prop == Tables::GRAPHEME_BOTH_EXTEND_ICB_EXTEND ||
      prop == Tables::GRAPHEME_BOTH_EXTEND_ICB_LINKER ||
      zwj?(prop)
  end

  private def self.zwj?(prop : UInt8) : Bool
    prop == Tables::GRAPHEME_ZWJ || prop == Tables::GRAPHEME_BOTH_ZWJ_ICB_EXTEND
  end

  private def self.icb_extend?(prop : UInt8) : Bool
    prop == Tables::GRAPHEME_ICB_EXTEND ||
      prop == Tables::GRAPHEME_BOTH_ZWJ_ICB_EXTEND ||
      prop == Tables::GRAPHEME_BOTH_EXTEND_ICB_EXTEND
  end

  private def self.icb_linker?(prop : UInt8) : Bool
    prop == Tables::GRAPHEME_ICB_LINKER || prop == Tables::GRAPHEME_BOTH_EXTEND_ICB_LINKER
  end
end
