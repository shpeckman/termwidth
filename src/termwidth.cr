# src/termwidth.cr
require "./termwidth/tables"
require "./termwidth/utf8"
require "./termwidth/grapheme"
require "./termwidth/props"
require "./termwidth/cluster"
require "./termwidth/segmenter"
require "./termwidth/width_profile"

module TermWidth
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify }}
end
