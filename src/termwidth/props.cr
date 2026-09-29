# src/termwidth/props.cr
require "./tables"

module TermWidth::Props
  DEFAULT = Tables::DEFAULT_PROP

  def self.pair(cp : UInt32) : UInt16
    Tables.prop_pair(cp)
  end

  def self.lookup(cp : UInt32) : UInt8
    Tables.width_prop(cp)
  end

  def self.width(prop : UInt8) : UInt8
    prop & Tables::WIDTH_MASK
  end

  def self.ambiguous?(prop : UInt8) : Bool
    (prop & Tables::AMBIGUOUS_BIT) != 0_u8
  end

  def self.pictographic?(prop : UInt8) : Bool
    (prop & Tables::PICTOGRAPHIC_BIT) != 0_u8
  end
end
