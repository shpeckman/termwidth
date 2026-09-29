# termwidth

Grapheme cluster segmentation and terminal cell-width measurement for Crystal,
implemented entirely in Crystal on a generated three-stage Unicode trie that
fuses cell width, pictographic flags, and UAX #29 grapheme-break properties
into a single lookup.

Beyond plain segmentation, the shard models how real terminals render text:
configurable width rules, emoji/VS15/VS16/keycap/flag handling, and a
calibration profile format that captures a terminal's actual behavior
(including the widths no rule can explain).

- Unicode 17.0.0 data tables, pinned and verified against `GraphemeBreakTest.txt`
- Zero-allocation iteration over clusters (`Bytes` slices, no strings)
- Automatic printable ASCII run coalescing
- No runtime dependencies or native build step

## Installation

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  termwidth:
    github: shpeckman/termwidth
```

or point at a git remote once the shard is published. Then:

```sh
shards install
```

The generated Unicode tables ship with the shard. Installation only compiles
Crystal code and does not download data, run a `postinstall` hook, or require
a C toolchain.

Requires Crystal `>= 1.21.0`.

## Usage

```crystal
require "termwidth"
```

### Segmenting and measuring

```crystal
seg = TermWidth::Segmenter::NARROW   # standard Unicode widths
seg = TermWidth::Segmenter::WIDE     # ambiguous-width codepoints take 2 cells
seg = TermWidth::Segmenter.new(TermWidth::WidthProfile::CAUTIOUS)

seg.each("ab日é ") do |cluster, width|
  # cluster : Bytes (a slice of the input), width : UInt8 (cells)
end

seg.each_span("ab日é ") do |span, width, ascii_run|
  # like each, but printable ASCII is coalesced into runs (ascii_run == true)
end

seg.measure("ab日é ") # => 6  (total cells)
seg.count("é🇺🇸")   # => 2  (clusters, not codepoints)
seg.codepoint_width(0x65E5_u32)   # => 2
```

`each`/`each_span` accept `Bytes` or `String` and never allocate: clusters are
slices of the input.

### Width profiles

A `WidthProfile` bundles a set of `Rule` flags with two `Category` masks
describing measurements a terminal makes that no rule reproduces:

```crystal
profile = TermWidth::WidthProfile::UNICODE
profile.rules       # TermWidth::Rule flags
profile.volatile    # categories whose width varies by terminal state
profile.lead_in     # categories whose width depends on the preceding character
profile.rule_names  # => "clusters,pair-flags,lone-ri-wide,vs16-widens,modifier-merges,keycap-wide"
```

Rules: `Clusters` (UAX #29 clusters vs. codepoints), `AmbiguousWide`,
`PairFlags`, `LoneRiWide`, `Vs16Widens`, `Vs15Narrows`, `ModifierMerges`,
`KeycapWide`, `SpacingWidens`.

Profiles can be inferred from terminal measurements — feed
`WidthProfile.infer` a set of `Sample`s (text plus observed width, optionally
at screen edge and after a leading character) and it picks the best rule set
and blames unexplainable widths on `volatile`/`lead_in` categories:

```crystal
samples = TermWidth::WidthProfile::CALIBRATION.map do |text|
  TermWidth::WidthProfile::Sample.new(text, measured_width_of(text))
end
profile = TermWidth::WidthProfile.infer(samples)
```

`TermWidth::WidthProfile.categories(text)` reports which `Category` flags
(`Ambiguous`, `Flag`, `Zwj`, `Vs16`, `Combining`, `Conjunct`, `Jamo`, …) a
piece of text falls into.

### Low-level pieces

```crystal
TermWidth::Props.lookup(0x1F600_u32)  # packed width-property byte from the trie
TermWidth::Props.pair(0x1F600_u32)    # fused width|grapheme pair, one trie walk
TermWidth::Props.width(prop)          # 0, 1, or 2
TermWidth::Props.ambiguous?(prop)
TermWidth::Props.pictographic?(prop)

cp, used = TermWidth::Utf8.decode(bytes, 0)  # strict, replaces malformed input
TermWidth::Utf8.encoded_length(cp)

TermWidth.classify(bytes)      # Category bitmask for a cluster
TermWidth.classify_cp(cp)      # same, for a single codepoint
TermWidth.scan_printable(bytes)  # length of the printable-ASCII run at offset 0
TermWidth.segment(bytes, from, rules, dst)  # raw batched segmentation
```

`TermWidth::Tables::UNICODE_VERSION` reports the pinned Unicode version.

## API reference

### `TermWidth`

**`VERSION : String`**  
Shard version, read from `shard.yml` at compile time.

**`segment(bytes : Bytes, from : Int32, rules : UInt32, dst : Slice(Cluster)) : Int32`**  
Batch-segment `bytes[from..]` into `dst`, returning the cluster count.  
This is the zero-allocation kernel behind `each`/`each_span`.

**`classify(bytes : Bytes) : UInt32`**  
**`classify_cp(cp : UInt32) : UInt32`**  
`Category` bitmask of a byte range (typically one cluster) / of a single codepoint.

**`scan_printable(bytes : Bytes, from : Int32 = 0) : Int32`**  
Length of the printable-ASCII run starting at `from` (word-at-a-time scan).

**`props(cp : UInt32) : UInt8`**  
Packed width-property byte (`Props.lookup`).

### `TermWidth::Segmenter`

**`Segmenter.new(profile : WidthProfile = WidthProfile::UNICODE)`**

**`Segmenter::NARROW`**  
**`Segmenter::WIDE`**  
Shared instances for the `UNICODE` and `UNICODE_WIDE` profiles.

**`#profile : WidthProfile`**

**`#each(bytes : Bytes, & : Bytes, UInt8 ->) : Nil`**  
**`#each(text : String, & : Bytes, UInt8 ->) : Nil`**  
Yield each cluster as a slice of the input with its cell width.

**`#each_span(bytes : Bytes, & : Bytes, UInt8, Bool ->) : Nil`**  
**`#each_span(text : String, & : Bytes, UInt8, Bool ->) : Nil`**  
Like `each`, but printable ASCII is coalesced into runs; the `Bool` marks run slices.

**`#measure(bytes : Bytes) : Int32`** / **`#measure(text : String) : Int32`**  
Total cells.

**`#count(bytes : Bytes) : Int32`** / **`#count(text : String) : Int32`**  
Cluster count.

**`#codepoint_width(cp : UInt32) : UInt8`**  
Cells for one codepoint under the profile.

### `TermWidth::WidthProfile`

**`WidthProfile.new(rules : Rule, volatile : Category = Category::None, lead_in : Category = Category::None)`**

**`WidthProfile::UNICODE`**  
**`WidthProfile::UNICODE_WIDE`**  
**`WidthProfile::CAUTIOUS`**  
Preset profiles.

**`WidthProfile::CALIBRATION : Array(String)`**  
Probe strings covering every width-relevant category.

**`WidthProfile::SANITY : Hash(String, Int32)`**  
Minimal expected widths; `infer` returns `CAUTIOUS` when a terminal fails
these.

**`#rules : Rule`**  
**`#volatile : Category`**  
**`#lead_in : Category`**

**`#rule_names : String`**  
**`#volatile_names : String`**  
**`#lead_in_names : String`**  
Comma-joined flag names, or `"none"`.

**`#wide_ambiguous? : Bool`**  
**`#clusters? : Bool`**  
Rule shorthands.

**`#volatile?(categories : Category) : Bool`**  
**`#lead_in?(categories : Category) : Bool`**  
Mask membership tests.

**`#shaped? : Bool`**  
Any volatile or lead-in categories present.

**`#to_s(io : IO) : Nil`**  
`"rules=… volatile=… lead-in=…"`.

**`WidthProfile.categories(text : String) : Category`**  
Accumulated category mask of a text.

**`WidthProfile.infer(samples : Enumerable(Sample)) : WidthProfile`**  
The best-fitting profile for a set of terminal measurements.

#### `WidthProfile::Sample`

**`record Sample, text : String, width : Int32?, edge : Int32? = nil, lead : Int32? = nil`**

**`#consistent? : Bool`**  
The edge and lead measurements agree with `width`.

**`#fixed_by_lead?(predicted : Int32) : Bool`**  
The mismatch against `predicted` is explained solely by the leading character.

### `TermWidth::Rule`

`@[Flags] enum Rule : UInt32` — `Clusters`, `AmbiguousWide`, `PairFlags`,
`LoneRiWide`, `Vs16Widens`, `Vs15Narrows`, `ModifierMerges`, `KeycapWide`,
`SpacingWidens`.

### `TermWidth::Category`

`@[Flags] enum Category : UInt16` — `Ambiguous`, `LoneRi`, `Flag`, `Zwj`,
`Modifier`, `Vs16`, `Vs15`, `Keycap`, `Combining`, `Conjunct`, `Jamo`.

### `TermWidth::Props`

**`Props::DEFAULT : UInt8`**  
Property byte for unassigned codepoints.

**`lookup(cp : UInt32) : UInt8`**  
Packed width byte (cells 0–2 plus the ambiguous and pictographic bits).

**`pair(cp : UInt32) : UInt16`**  
Fused `width byte | grapheme byte << 8` from a single trie walk.

**`width(prop : UInt8) : UInt8`**  
Cell count 0, 1, or 2.

**`ambiguous?(prop : UInt8) : Bool`**  
**`pictographic?(prop : UInt8) : Bool`**

### `TermWidth::Utf8`

**`Utf8::REPLACEMENT : UInt32`**  
U+FFFD, substituted for malformed sequences.

**`decode(bytes : Bytes, index : Int32) : {UInt32, Int32}`**  
`{codepoint, bytes consumed}`; strict, replaces malformed input with U+FFFD.

**`encoded_length(cp : UInt32) : Int32`**  
**`sequence_length(lead : UInt8) : Int32`**  
**`continuation?(byte : UInt8) : Bool`**

### `TermWidth::Cluster`

**`struct Cluster`**  
One segmented cluster: `start : Int32`, `length : Int32`, `width : UInt8`,
`flags : UInt8` (plus `reserved : UInt16`), all defaulting to zero in
`Cluster.new`.  
Flag bits: **`CLUSTER_ASCII_RUN`**. The batch kernel fills slices of up to
**`SEGMENT_BATCH`** clusters per call.

### `TermWidth::Grapheme`

**`Grapheme.property(cp : UInt32) : UInt8`**  
UAX #29 grapheme-break property byte.

**`Grapheme.break?(prev : UInt32, cp : UInt32, state : State*) : Bool`**  
**`Grapheme.break?(prev : UInt32, cp_prop : UInt8, state : State*) : Bool`**  
Boundary decision between `prev` and the next codepoint, threading `state`.  
The `UInt8` overload skips the property lookup when you already hold one (e.g.
the high byte of `Props.pair`).

**`struct Grapheme::State`**  
Mutable state with `prop`, `prop_set`, `gb11`, `gb12_13`, `gb9c_level`
properties; `State.new` starts a fresh run.

### `TermWidth::Tables`

**`Tables::UNICODE_VERSION : String`**  
UCD version the tables were generated from. The trie itself (`prop_pair`,
`width_prop`, `grapheme_prop` and the `PROP_*` arrays) is generated code;
prefer `Props`/`Grapheme` over touching it directly.

## Development

```sh
crystal spec                    # run the spec suite
crystal tool/verify_unicode.cr  # check segmentation against GraphemeBreakTest.txt
crystal tool/fetch_ucd.cr       # fetch the pinned UCD files into tool/ucd
crystal tool/gen_unicode.cr     # regenerate src/termwidth/tables.cr
```

The batched kernel is checked against an independent span-building reference
(`spec/support/reference.cr`) on the Unicode conformance data, randomized text,
and malformed byte sequences.

## License

MIT
