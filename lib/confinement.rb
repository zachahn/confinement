if Gem.loaded_specs.has_key?("pry-byebug")
  require "pry-byebug"
elsif Gem.loaded_specs.has_key?("pry-byebug")
  require "pry"
end

require "open3"
require "pathname"

require "confinement/version"

module Confinement
  class Error < StandardError
    class PathDoesNotExist < Error; end
  end

  class << self
    attr_reader :root
    attr_accessor :site

    def root=(path)
      # NOTE: Pathname.new(Pathname.new(".")) == Pathname.new(".")
      path = Pathname.new(path).expand_path
      path = path.expand_path

      if !path.exist?
        raise Error::PathDoesNotExist, "Root path does not exist: #{path}"
      end

      @root = path
    end
  end

  class Builder
    def initialize(root:, assets:, contents:, layouts:, config: {})
      @root = root
      @assets = assets
      @contents = contents
      @layouts = layouts
      @config = {
        index: config.fetch(:index, "index.html")
      }

      @output_root = root.join(root.join(config.fetch(:destination_root, "public")))
      @assets_root = @output_root.join(config.fetch(:assets_subdirectory, "assets"))

      @representation = Representation.new
    end

    attr_reader :root
    attr_reader :output_root
    attr_reader :assets_root
    attr_reader :representation
    attr_reader :config

    def contents
      if !contents_path.exist?
        raise PathDoesNotExist, "Contents path doesn't exist: #{contents_path}"
      end

      yield(contents_path, @representation.contents)
    end

    def assets
      if !assets_path.exist?
        raise PathDoesNotExist, "Assets path doesn't exist: #{assets_path}"
      end

      yield(assets_path, @representation.assets)
    end

    private

    def contents_path
      @root.join(@contents)
    end

    def assets_path
      @root.join(@assets)
    end
  end

  class Representation
    include Enumerable

    def initialize
      @lookup = {}
    end

    def each
      if !block_given?
        return enum_for(:each)
      end

      @lookup.each do |identifier, page|
        yield(identifier, page)
      end
    end

    def contents
      ContentsSetter.new(@lookup)
    end

    def assets
      AssetsSetter.new(@lookup)
    end

    class ContentsSetter
      def initialize(lookup)
        @lookup = lookup
      end

      def []=(key, value)
        @lookup[key] = value
        @lookup[key].url_path = key
        @lookup[key]
      end
    end

    class AssetsSetter
      def initialize(lookup)
        @lookup = lookup
      end

      def []=(key, value)
        @lookup[key] = value
        @lookup[key]
      end
    end
  end

  class Page
    # @param layout [String] the ActionPack layout
    # @param input_path [Pathname] path to source
    # @param frontmatter [Hash] Optional, overrides from "input_path"
    # @param body [String] Optional, overrides value from "input_path"
    def initialize(layout: nil, input_path: nil, frontmatter: nil, body: nil, locals: {})
      @layout = layout
      @input_path = input_path
      @frontmatter = frontmatter
      @body = body
      @locals = locals

      @url_path = nil
    end

    attr_reader :input_path
    attr_reader :output_path
    attr_reader :url_path

    def url_path=(path)
      path = path.to_s
      if path[0] != "/"
        path = "/#{path}"
      end

      @url_path = path
    end
  end

  class Asset
    def initialize(input_path:, entrypoint:)
      @input_path = input_path
      @entrypoint = entrypoint
      @output_path = nil
      @url_path = nil
    end

    attr_reader :input_path
    attr_accessor :output_path
    attr_reader :url_path

    def url_path=(path)
      path = path.to_s
      if path[0] != "/"
        path = "/#{path}"
      end

      @url_path = path
    end

    def entrypoint?
      !!@entrypoint
    end
  end

  class HesitantCompiler
    def initialize(site)
      @lock = Mutex.new

      @assets_hash = {}
    end

    def compile(site)
      assets = {}
      contents = {}

      site.representation.each do |identifier, page|
        if page.kind_of?(Asset)
          assets[identifier] = page
        else
          contents[identifier] = page
        end
      end

      # Assets first since it's almost always a dependency of contents
      compile_assets(site, assets)
      compile_contents(site, contents)
    end

    private

    PARCEL_FILES_OUTPUT_REGEX = /^✨[^\n]+\n\n(.*)Done in(?:.*)\z/m
    PARCEL_FILE_OUTPUT_REGEX = /^(?<page>.*?)\s+(?<size>[0-9\.]+\s*[A-Z]?B)\s+(?<time>[0-9\.]+[a-z]?s)$/

    def compile_assets(site, assets)
      @lock.synchronize do
        if assets_dirty?
          out, status = Open3.capture2(
            "yarn",
            "run",
            "parcel",
            "build",
            "--dist-dir", site.assets_root.to_s,
            "--public-url", site.assets_root.basename.to_s,
            *assets.values.select(&:entrypoint?).map(&:input_path).map(&:to_s)
          )

          if !status.success?
            raise "Asset compilation failed"
          end

          matches = PARCEL_FILES_OUTPUT_REGEX.match(out)[1]

          if !matches
            raise "Asset parsing failed"
          end

          processed_file_paths = matches.split("\n\n")

          representation_by_input_path =
            site.representation.filter_map do |_, page|
              next if page.input_path.nil?

              [page.input_path, page]
            end
            .to_h

          parsed_parcel_output = processed_file_paths.map do |file|
            output_file, input_file = file.strip.split("\n└── ")

            output_path = site.root.join(output_file[PARCEL_FILE_OUTPUT_REGEX, 1])
            input_path = site.root.join(input_file[PARCEL_FILE_OUTPUT_REGEX, 1])

            if !representation_by_input_path.key?(input_path)
              next
            end

            url_path = output_path.relative_path_from(site.output_root)
            representation_by_input_path[input_path].url_path = url_path.to_s
            representation_by_input_path[input_path].output_path = output_path
          end
        end
      end
    end

    def compile_contents(site, contents)
      @lock.synchronize do
      end
    end

    private

    def assets_dirty?
      true
    end
  end

  class Publish
    def initialize(site)
      @site = site
      @compiler = HesitantCompiler.new(@site)
    end

    def write(path)
      find_or_raise_or_mkdir(path)

      puts "== Before"
      pp @site.representation
      @compiler.compile(@site)
      puts
      puts "== After"
      pp @site.representation
    end

    private

    def find_or_raise_or_mkdir(destination)
      if !destination.exist?
        if !destination.dirname.exist?
          raise Error::PathDoesNotExist, "Destination's parent path does not exist: #{destination.dirname}"
        end

        destination.mkpath
      end
    end
  end

  module Easier
  end
end
