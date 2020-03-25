# frozen_string_literal: true

if Gem.loaded_specs.has_key?("pry-byebug")
  require "pry-byebug"
elsif Gem.loaded_specs.has_key?("pry-byebug")
  require "pry"
end

# standard library
require "open3"
require "pathname"
require "yaml"

# gems
require "erubi"

# internal
require_relative "confinement/version"

module Confinement
  class Error < StandardError
    class PathDoesNotExist < Error; end
  end

  FRONTMATTER_REGEX =
    /\A
      (?<frontmatter_section>
      (?<frontmatter>^---\n
      .*?)
      ^---\n)?
      (?<body>.*)\z/mx

  module Easier
    # NOTE: Avoid state - Pathname is supposed to be immutable
    refine Pathname do
      # Pathname#join and File.join behave very differently
      #
      # - Pathname.new("foo").join("/bar") # => Pathname.new("/bar")
      # - File.join("foo", "/bar") # => "foo/bar"
      def concat(*parts)
        Pathname.new(File.join(self, *parts))
      end

      def include?(other)
        difference = other.relative_path_from(self)

        difference.to_s !~ /\A..\b/
      end
    end

    refine String do
      def frontmatter_and_body(strip: true)
        matches = FRONTMATTER_REGEX.match(self)
        frontmatter = matches["frontmatter"] || ""
        frontmatter = YAML.safe_load(frontmatter)
        body = matches["body"] || ""
        body = body.strip if strip

        [frontmatter, body]
      end
    end
  end

  using Easier

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

      @output_root = root.concat(config.fetch(:destination_root, "public"))
      @assets_root = @output_root.concat(config.fetch(:assets_subdirectory, "assets"))

      @representation = Representation.new
    end

    attr_reader :root
    attr_reader :output_root
    attr_reader :assets_root
    attr_reader :representation
    attr_reader :config

    def contents_path
      @contents_path ||= @root.concat(@contents)
    end

    def layouts_path
      @layouts_path ||= @root.concat(@contents)
    end

    def assets_path
      @assets_path ||= @root.concat(@assets)
    end

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
  end

  class Representation
    include Enumerable

    def initialize
      @lookup = {}
    end

    def fetch(key)
      if !@lookup.key?(key)
        raise "Not represented!"
      end

      @lookup[key]
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

  class View
    # @param layout [String] the ActionPack layout
    # @param input_path [Pathname] path to source
    # @param frontmatter [Hash] Optional, overrides from "input_path"
    # @param body [String] Optional, overrides value from "input_path"
    def initialize(layout: nil, input_path: nil, frontmatter: nil, body: nil, locals: {}, renderers: [])
      @layout = layout
      @input_path = input_path
      @frontmatter = frontmatter
      @body = body
      @locals = locals
      @renderers = renderers

      @url_path = nil
    end

    attr_reader :input_path
    attr_accessor :output_path
    attr_accessor :rendered_body
    attr_reader :url_path
    attr_reader :locals
    attr_reader :renderers

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

  class Renderer
    class Erb
      def call(source, view_context, &block)
        compiled_erb = Erubi::Engine.new(source).src

        view_context.instance_eval(compiled_erb, &block)
      end
    end
  end

  class Rendering
    # TODO: Merge ViewContext and View
    class ViewContext
      def initialize(routes:, locals:, contents_path:, layouts_path:)
        self.parent_context = nil
        self.locals = locals
        self.routes = routes

        @contents_path = contents_path
        @layouts_path = layouts_path
      end

      attr_accessor :routes
      attr_accessor :parent_context
      attr_accessor :locals
      attr_accessor :frontmatter
      attr_reader :contents_path
      attr_reader :layouts_path

      def dup_for_chain
        the_dup = dup
        the_dup.parent_context = self

        the_dup
      end

      def render(path = nil, inline: nil, renderers:, &block)
        body =
          if path
            path.read
          elsif inline
            inline
          else
            raise %(Must pass in either a Pathname or `inline: 'text'`)
          end

        RenderChain.new(body: body, renderers: renderers, view_context: self).call(&block)
      end
    end

    class RenderChain
      def initialize(body:, renderers:, view_context:)
        @body = body
        @renderers = renderers
        @view_context = view_context
      end

      def call(&block)
        frontmatter, body = @body.frontmatter_and_body

        view_context = @view_context.dup_for_chain
        view_context.frontmatter = frontmatter

        @renderers.reduce(body) do |memo, renderer|
          renderer.call(memo, view_context, &block)
        end
      end
    end
  end

  class HesitantCompiler
    # As strange as it might seem, Routes is a public-facing interface to the
    # HesitantCompiler.
    #
    # Let's assume the following (by "depends on", I mean that it links to the page)
    #
    #     index.html.erb depends on
    #       about_me.html.erb which depends on
    #         i_love_star_trek.html.erb
    #
    # We don't know where the compiler will start. If the compiler compiles in
    # this order, we'll happen to have no dependency issues:
    #
    # 1. i_love_star_trek.html.erb
    # 2. about_me.html.erb
    # 3. index.html.erb
    #
    # However it's just as likely that `index.html.erb` would be compiled first.
    # In that case, since the views will be accessing routes via this class
    #
    # How do we handle circular dependencies? With the circular flag, which
    # bypasses compilation. But this is relatively dangerous.
    class Routes
      def initialize(representation, compiler)
        @representation = representation
        @compiler = compiler
      end

      def [](identifier, circular: false)
        page = @representation.fetch(identifier)

        if page.rendered_body || circular
          return page
        end

        compile(page)

        page
      end

      private

      def compile(page)
        @compiler.send(:compile_content, page)
      end
    end

    def initialize(site)
      @site = site
      @routes = Routes.new(@site.representation, self)
      @lock = Mutex.new
    end

    attr_reader :site

    def compile_everything
      assets = {}
      contents = {}

      site.representation.each do |identifier, page|
        if page.kind_of?(Asset)
          assets[identifier] = page
        else
          contents[identifier] = page
        end
      end

      # All compilation happens inside the same lock. So we shouldn't have
      # to worry about deadlocks or anything
      @lock.synchronize do
        # Assets first since it's almost always a dependency of contents
        compile_assets(assets)
        compile_contents(contents)
      end
    end

    private

    PARCEL_FILES_OUTPUT_REGEX = /^✨[^\n]+\n\n(.*)Done in(?:.*)\z/m
    PARCEL_FILE_OUTPUT_REGEX = /^(?<page>.*?)\s+(?<size>[0-9\.]+\s*[A-Z]?B)\s+(?<time>[0-9\.]+[a-z]?s)$/

    def compile_assets(assets)
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

          output_path = site.root.concat(output_file[PARCEL_FILE_OUTPUT_REGEX, 1])
          input_path = site.root.concat(input_file[PARCEL_FILE_OUTPUT_REGEX, 1])

          if !representation_by_input_path.key?(input_path)
            next
          end

          url_path = output_path.relative_path_from(site.output_root)
          representation_by_input_path[input_path].url_path = url_path.to_s
          representation_by_input_path[input_path].output_path = output_path
        end
      end
    end

    def compile_content(content)
      if content.rendered_body
        return
      end

      view_context = Rendering::ViewContext.new(
        routes: @routes,
        locals: content.locals,
        contents_path: site.contents_path,
        layouts_path: site.layouts_path
      )

      content_body = content.input_path.read
      content.rendered_body = view_context.render(inline: content_body, renderers: content.renderers) || ""

      content.output_path =
        if content.url_path[-1] == "/"
          site.output_root.concat(content.url_path, site.config.fetch(:index))
        else
          site.output_root.concat(content.url_path)
        end

      if content.output_path.exist?
        if content.output_path.read == content.rendered_body
          return
        end
      end

      if !site.output_root.include?(content.output_path)
        return
      end

      if !content.output_path.dirname.directory?
        content.output_path.dirname.mkpath
      end

      content.output_path.write(content.rendered_body)

      nil
    end

    def compile_contents(contents)
      return if !contents_dirty?

      contents.each do |_identifier, content|
        compile_content(content)
      end
    end

    private

    def contents_dirty?
      true
    end

    def assets_dirty?
      false
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
      @compiler.compile_everything
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
end
