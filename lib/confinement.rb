# frozen_string_literal: true

if Gem.loaded_specs.has_key?("pry-byebug")
  require "pry-byebug"
elsif Gem.loaded_specs.has_key?("pry-byebug")
  require "pry"
end

# standard library
require "digest"
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

  PATH_INCLUDE_PATH_REGEX = /\A\.\.(\z|\/)/

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

        !PATH_INCLUDE_PATH_REGEX.match?(difference.to_s)
      end
    end

    refine String do
      def frontmatter_and_body(strip: true)
        matches = FRONTMATTER_REGEX.match(self)

        return [{}, self] if matches["frontmatter"].nil?

        frontmatter = YAML.safe_load(matches["frontmatter"])
        body = matches["body"] || ""
        body = body.strip if strip

        [frontmatter, body]
      rescue ArgumentError
        [{}, self]
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
      @layouts_path ||= @root.concat(@layouts)
    end

    def assets_path
      @assets_path ||= @root.concat(@assets)
    end

    def contents
      if !contents_path.exist?
        raise PathDoesNotExist, "Contents path doesn't exist: #{contents_path}"
      end

      yield(contents_path, layouts_path, @representation.contents)
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
      @grouped_assets = []
      @grouped_contents = []
    end

    attr_reader :grouped_assets
    attr_reader :grouped_contents

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
      LookupSetter.new(@lookup, @grouped_contents, set_url_path: true)
    end

    def assets
      LookupSetter.new(@lookup, @grouped_assets, set_url_path: false)
    end

    def getter
      LookupGetter.new(@lookup)
    end

    class LookupSetter
      def initialize(lookup, group, set_url_path:)
        @lookup = lookup
        @group = group
        @set_url_path = set_url_path
      end

      def []=(key, value)
        @group.push(value)

        @lookup[key] = value
        @lookup[key].url_path = key if @set_url_path
        @lookup[key]
      end
    end

    class LookupGetter
      def initialize(lookup)
        @lookup = lookup
      end

      def [](key)
        @lookup.fetch(key)
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
    attr_reader :layout

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
        method_name = "_#{Digest::MD5.hexdigest(source)}"

        compile(method_name, source, view_context)

        view_context.public_send(method_name, &block)
      end

      private

      def compile(method_name, source, view_context)
        if !view_context.respond_to?(method_name)
          compiled_erb = Erubi::Engine.new(source).src

          view_context.instance_eval(<<~RUBY, __FILE__, __LINE__ + 1)
            def #{method_name}
              #{compiled_erb}
            end
          RUBY
        end
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

      def render(path = nil, layout: nil, inline: nil, renderers:, &block)
        body =
          if path
            path.read
          elsif inline
            inline
          else
            raise %(Must pass in either a Pathname or `inline: 'text'`)
          end

        duped_view_context = dup_for_chain

        render_chain = RenderChain.new(
          body: body,
          layout: layout,
          renderers: renderers,
          view_context: duped_view_context
        )
        rendered_body = render_chain.call(&block)

        if layout
          layout_render_chain = RenderChain.new(
            body: layout.read,
            layout: nil,
            renderers: renderers,
            view_context: duped_view_context
          )

          layout_render_chain.call do
            rendered_body
          end
        else
          rendered_body
        end
      end

      private

      def dup_for_chain
        the_dup = dup
        the_dup.parent_context = self

        the_dup
      end
    end

    class RenderChain
      def initialize(body:, layout:, renderers:, view_context:)
        @body = body
        @layout = layout
        @renderers = renderers
        @view_context = view_context
      end

      def call(&block)
        frontmatter, body = @body.frontmatter_and_body

        @view_context.frontmatter = frontmatter

        @renderers.reduce(body) do |memo, renderer|
          renderer.call(memo, @view_context, &block)
        end
      end
    end
  end

  class HesitantCompiler
    def initialize(site)
      @site = site
      @lock = Mutex.new
    end

    attr_reader :site

    def compile_everything
      # All compilation happens inside the same lock. So we shouldn't have
      # to worry about deadlocks or anything
      @lock.synchronize do
        # Assets first since it's almost always a dependency of contents
        compile_assets(site.representation.grouped_assets)
        compile_contents(site.representation.grouped_contents)
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
          *assets.select(&:entrypoint?).map(&:input_path).map(&:to_s)
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
          site.representation.grouped_assets.filter_map do |page|
            next if page.input_path.nil?

            [page.input_path, page]
          end
          .to_h

        processed_file_paths.map do |file|
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
        routes: site.representation.getter,
        locals: content.locals,
        contents_path: site.contents_path,
        layouts_path: site.layouts_path
      )

      content_body = content.input_path.read
      content.rendered_body = view_context.render(
        inline: content_body,
        layout: content.layout,
        renderers: content.renderers
      )
      content.rendered_body ||= ""

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

      contents.each do |content|
        compile_content(content)
      end
    end

    private

    def contents_dirty?
      true
    end

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

      @compiler.compile_everything
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
