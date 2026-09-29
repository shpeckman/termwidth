# spec/spec_helper.cr

require "spec"
require "../src/termwidth"

include TermWidth

def clusters(text : String, segmenter : Segmenter = Segmenter::NARROW) : Array(Tuple(String, UInt8))
  acc = [] of Tuple(String, UInt8)
  segmenter.each(text.to_slice) { |cluster, width| acc << {String.new(cluster), width} }
  acc
end

def widths(text : String, segmenter : Segmenter = Segmenter::NARROW) : Array(UInt8)
  clusters(text, segmenter).map(&.[1])
end
