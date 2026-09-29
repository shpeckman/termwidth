# src/termwidth/segmenter.cr
require "./props"
require "./width_profile"
require "./cluster"

module TermWidth
  struct Segmenter
    getter profile : WidthProfile

    @rules : UInt32

    def initialize(@profile : WidthProfile = WidthProfile::UNICODE)
      @rules = @profile.rules.value
    end

    NARROW = new(WidthProfile::UNICODE)
    WIDE   = new(WidthProfile::UNICODE_WIDE)

    def each(bytes : Bytes, & : Bytes, UInt8 ->) : Nil
      each_span(bytes) do |span, width, ascii|
        if ascii
          ptr = span.to_unsafe
          ro  = span.read_only?
          k   = 0
          while k < span.size
            yield Bytes.new(ptr + k, 1, read_only: ro), 1_u8
            k += 1
          end
        else
          yield span, width
        end
      end
    end

    def each(text : String, & : Bytes, UInt8 ->) : Nil
      each(text.to_slice) { |cluster, width| yield cluster, width }
    end

    def each_span(bytes : Bytes, & : Bytes, UInt8, Bool ->) : Nil
      n = bytes.size
      return if n == 0

      batch = uninitialized StaticArray(Cluster, SEGMENT_BATCH)
      recs = batch.to_slice
      ptr  = bytes.to_unsafe
      ro   = bytes.read_only?
      off  = 0

      while off < n
        count = TermWidth.segment(bytes, off, @rules, recs)
        break if count == 0
        k = 0
        while k < count
          rec = recs.unsafe_fetch(k)
          yield Bytes.new(ptr + off + rec.start, rec.length, read_only: ro), rec.width,
            (rec.flags & CLUSTER_ASCII_RUN) != 0_u8
          k += 1
        end
        last = recs.unsafe_fetch(count - 1)
        off += last.start + last.length
      end
    end

    def each_span(text : String, & : Bytes, UInt8, Bool ->) : Nil
      each_span(text.to_slice) { |span, width, ascii| yield span, width, ascii }
    end

    def measure(bytes : Bytes) : Int32
      total = 0
      each_span(bytes) { |span, width, ascii| total += ascii ? span.size : width.to_i }
      total
    end

    def measure(text : String) : Int32
      measure(text.to_slice)
    end

    def count(bytes : Bytes) : Int32
      total = 0
      each_span(bytes) { |span, _, ascii| total += ascii ? span.size : 1 }
      total
    end

    def count(text : String) : Int32
      count(text.to_slice)
    end

    def codepoint_width(cp : UInt32) : UInt8
      prop = Props.lookup(cp)
      return 2_u8 if @profile.wide_ambiguous? && Props.ambiguous?(prop)
      Props.width(prop)
    end
  end
end
