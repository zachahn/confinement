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
require "erubi/capture_end"

# internal
require_relative "confinement/version"

module Confinement
  class Error < StandardError
    class PathDoesNotExist < Error; end
  end

  FRONTMATTER_REGEX =
    /\A
      (?<possible_frontmatter_section>
        (?<frontmatter>^---\n
        .*?)
        ^---\n)?
      (?<body>.*)
    \z/mx

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

        frontmatter = YAML.load(matches["frontmatter"], symbolize_names: true)
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

    def layouts
      if !layouts_path.exist?
        raise PathDoesNotExist, "Layouts path doesn't exist: #{layouts_path}"
      end

      yield(layouts_path, @representation.layouts)
    end

    def assets
      if !assets_path.exist?
        raise PathDoesNotExist, "Assets path doesn't exist: #{assets_path}"
      end

      yield(assets_path, @representation.assets)
    end

    def contents
      if !contents_path.exist?
        raise PathDoesNotExist, "Contents path doesn't exist: #{contents_path}"
      end

      yield(contents_path, layouts_path, @representation.contents)
    end
  end

  class Representation
    include Enumerable

    def initialize
      @lookup = {}
      @layouts_lookup = {}
      @only_assets = []
      @only_contents = []
    end

    attr_reader :only_assets
    attr_reader :layouts_lookup
    attr_reader :only_contents

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

    def layouts
      Setter.new(@layouts_lookup) do |path, layout|
        layout.input_path = path
      end
    end

    def assets
      Setter.new(@lookup) do |identifier, asset|
        @only_assets.push(asset)
        asset.url_path = identifier
      end
    end

    def contents
      Setter.new(@lookup) do |identifier, content|
        @only_contents.push(content)
        content.url_path = identifier
      end
    end

    def routes_getter
      LookupGetter.new(@lookup)
    end

    def layouts_getter
      LookupGetter.new(@layouts_lookup)
    end

    class Setter
      def initialize(lookup, &block)
        @lookup = lookup
        @block = block
      end

      def []=(key, value)
        @block&.call(key, value)

        @lookup[key] = value
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

  module Blob
    attr_accessor :input_path
    attr_accessor :output_path
    attr_reader :url_path

    def url_path=(path)
      if path.nil?
        @url_path = nil
        return
      end

      path = path.to_s
      if path[0] != "/"
        path = "/#{path}"
      end

      @url_path = path
    end
  end

  class Asset
    include Blob

    def initialize(input_path:, entrypoint:)
      self.input_path = input_path

      @entrypoint = entrypoint
      @url_path = nil
    end

    attr_accessor :rendered_body

    def entrypoint?
      !!@entrypoint
    end
  end

  class Content
    include Blob

    def initialize(layout: nil, input_path: nil, locals: {}, renderers: [])
      self.input_path = input_path

      @layout = layout
      @locals = locals
      @renderers = renderers
    end

    attr_reader :locals
    attr_reader :renderers
    attr_reader :layout

    attr_accessor :rendered_body
  end

  class Layout
    def initialize(renderers:)
      @renderers = renderers
    end

    attr_reader :renderers
    attr_accessor :input_path
  end

  class Renderer
    class Erb
      def call(source, view_context, path:, &block)
        method_name =
          if path
            "_#{Digest::MD5.hexdigest(source)}__#{path.to_s.tr("^A-Za-z", "_")}"
          else
            "_#{Digest::MD5.hexdigest(source)}"
          end

        compile(method_name, source, view_context, path: path)

        view_context.public_send(method_name, &block)
      end

      private

      def compile(method_name, source, view_context, path:)
        if !view_context.respond_to?(method_name)
          compiled_erb = Erubi::CaptureEndEngine.new(source, bufvar: :@_buf, ensure: true).src

          eval_location =
            if path
              [path.to_s, 1]
            else
              []
            end

          view_context.instance_eval(<<~RUBY, *eval_location)
            def #{method_name}
              #{compiled_erb}
            end
          RUBY
        end
      end
    end
  end

  class Rendering
    class ViewContext
      def initialize(routes:, layouts:, locals:, frontmatter:, contents_path:, layouts_path:)
        @routes = routes
        @layouts = layouts

        @locals = locals
        @frontmatter = frontmatter

        @contents_path = contents_path
        @layouts_path = layouts_path
      end

      attr_reader :routes
      attr_reader :layouts
      attr_reader :locals
      attr_reader :frontmatter
      attr_reader :contents_path
      attr_reader :layouts_path

      def capture
        original_buffer = @_buf
        @_buf = +""
        return yield
      ensure
        @_buf = original_buffer
      end

      def render(path = nil, inline: nil, layout: nil, renderers:, &block)
        body =
          if inline
            inline
          elsif path
            path.read
          else
            raise %(Must pass in either a Pathname or `inline: 'text'`)
          end

        render_chain = RenderChain.new(
          body: body,
          path: path,
          renderers: renderers,
          view_context: self
        )
        rendered_body = render_chain.call(&block)

        if layout
          layout =
            if layout.is_a?(Layout)
              layout
            elsif layout.is_a?(Pathname)
              layouts[layout]
            else
              raise "Expected layout to be a Layout or Pathname"
            end

          layout_render_chain = RenderChain.new(
            body: layout.input_path.read,
            path: layout.input_path,
            renderers: layout.renderers,
            view_context: self
          )

          layout_render_chain.call do
            rendered_body
          end
        else
          rendered_body
        end
      end
    end

    class RenderChain
      def initialize(body:, path:, renderers:, view_context:)
        @body = body
        @path = path
        @renderers = renderers
        @view_context = view_context
      end

      def call(&block)
        @renderers.reduce(@body) do |memo, renderer|
          renderer.call(memo, @view_context, path: @path, &block)
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
        compile_assets(site.representation.only_assets)
        compile_contents(site.representation.only_contents)
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
          site.representation.only_assets.filter_map do |page|
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
          representation_by_input_path[input_path].rendered_body = output_path.read
        end
      end
    end

    def compile_content(content)
      if content.rendered_body
        return
      end

      content_body = content.input_path.read
      frontmatter, content_body = content_body.frontmatter_and_body

      view_context = Rendering::ViewContext.new(
        routes: site.representation.routes_getter,
        layouts: site.representation.layouts_getter,
        locals: content.locals,
        frontmatter: frontmatter,
        contents_path: site.contents_path,
        layouts_path: site.layouts_path
      )

      content.rendered_body = view_context.render(
        content.input_path,
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
