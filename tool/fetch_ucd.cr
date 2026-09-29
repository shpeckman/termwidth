# tool/fetch_ucd.cr
require "http/client"

module FetchUcd
  VERSION = "17.0.0"
  FILES   = {
    "auxiliary/GraphemeBreakProperty.txt" => "GraphemeBreakProperty.txt",
    "auxiliary/GraphemeBreakTest.txt"     => "GraphemeBreakTest.txt",
    "emoji/emoji-data.txt"                => "emoji-data.txt",
    "EastAsianWidth.txt"                  => "EastAsianWidth.txt",
    "UnicodeData.txt"                     => "UnicodeData.txt",
    "DerivedCoreProperties.txt"           => "DerivedCoreProperties.txt",
  }

  def self.run : Nil
    version = ARGV[0]? || VERSION
    base    = "https://www.unicode.org/Public/#{version}/ucd"
    dest    = File.join(__DIR__, "ucd")
    Dir.mkdir_p(dest)

    FILES.each do |path, name|
      target = File.join(dest, name)
      HTTP::Client.get("#{base}/#{path}") do |response|
        raise "failed to fetch #{path}: HTTP #{response.status_code}" unless response.status_code == 200
        File.open(target, "w") { |file| IO.copy(response.body_io, file) }
      end
      puts name
    end

    data = File.join(__DIR__, "..", "spec", "data")
    Dir.mkdir_p(data)
    File.write(File.join(data, "GraphemeBreakTest.txt"), File.read(File.join(dest, "GraphemeBreakTest.txt")))
  end
end

FetchUcd.run
