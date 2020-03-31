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

      def normalize_for_route
        "/#{self}".squeeze("/")
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

  class Site
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

      @route_identifiers = RouteIdentifiers.new
      @asset_blobs = Blobs.new(scoped_root: assets_path, file_abstraction_class: Asset)
      @content_blobs = Blobs.new(scoped_root: contents_path, file_abstraction_class: Content)
      @layout_blobs = Blobs.new(scoped_root: layouts_path, file_abstraction_class: Layout)
    end

    attr_reader :root
    attr_reader :output_root
    attr_reader :assets_root
    attr_reader :config

    attr_reader :route_identifiers
    attr_reader :asset_blobs
    attr_reader :content_blobs
    attr_reader :layout_blobs

    def build
      yield(
        assets: @asset_blobs,
        layouts: @layout_blobs,
        contents: @content_blobs,
        routes: @route_identifiers
      )

      @asset_blobs.done!
      @layout_blobs.done!
      @content_blobs.done!
      @route_identifiers.done!

      nil
    end

    def contents_path
      @contents_path ||= @root.concat(@contents).cleanpath
    end

    def layouts_path
      @layouts_path ||= @root.concat(@layouts).cleanpath
    end

    def assets_path
      @assets_path ||= @root.concat(@assets).cleanpath
    end
  end

  # RouteIdentifiers is called such because it doesn't hold the actual
  # content's route. The content's own `url_path` does.
  #
  # This is mainly so that assets could be referenced internally with a static
  # identifier even though it could have a hashed route.
  class RouteIdentifiers
    def initialize
      self.lookup = {}
    end

    def done!
      @done = true
    end

    def [](route)
      route = route.normalize_for_route

      if !lookup.key?(route)
        raise "Route is not defined"
      end

      self.lookup[route]
    end

    def []=(route, content)
      raise "Can't add more routes after initial setup" if @done

      route = route.normalize_for_route

      if lookup.key?(route)
        raise "Route already defined!"
      end

      content.url_path = route

      lookup[route] = content
    end

    private

    attr_accessor :lookup
  end

  class Blobs
    def initialize(scoped_root:, file_abstraction_class:)
      self.scoped_root = scoped_root
      self.file_abstraction_class = file_abstraction_class
      self.lookup = {}
      @done = false
    end

    def done!
      @done = true
    end

    def [](relpath)
      abspath = into_abspath(relpath)

      if !lookup.key?(abspath)
        raise "Don't know about this blob: #{abspath.inspect}"
      end

      lookup[abspath]
    end

    def init(relpath, **initializer_options)
      raise "Can't add more #{file_abstraction_class}s after the initial setup!" if @done

      abspath = into_abspath(relpath)
      lookup[abspath] ||= file_abstraction_class.new(input_path: abspath, **initializer_options)
      yield lookup[abspath] if block_given?
      lookup[abspath]
    end

    def init_many(pattern)
      files_lookup.filter_map do |relpath, abspath|
        if pattern.match?(relpath)
          lookup[abspath.to_s] ||= file_abstraction_class.new(input_path: abspath)
        end
      end
    end

    private

    def into_abspath(relpath)
      scoped_root.concat(relpath).cleanpath
    end

    def files_lookup
      @files_lookup ||=
        scoped_root
        .glob("**/*")
        .map { |path| [path.relative_path_from(scoped_root).to_s, path] }
        .to_h
    end

    attr_accessor :scoped_root
    attr_accessor :file_abstraction_class
    attr_accessor :lookup
  end

  module Blob
    attr_accessor :input_path
    attr_accessor :output_path
    attr_reader :url_path

    def url_path=(new_url_path)
      @url_path = new_url_path.normalize_for_route
    end
  end

  class Asset
    include Blob

    def initialize(input_path:, entrypoint:)
      self.input_path = input_path
      @entrypoint = entrypoint
    end

    attr_accessor :body

    def entrypoint?
      !!@entrypoint
    end
  end

  class Content
    include Blob

    def initialize(input_path:, layout: nil, locals: {}, renderers: [])
      self.input_path = input_path

      @layout = layout
      @locals = locals
      @renderers = renderers
    end

    attr_accessor :locals
    attr_accessor :renderers
    attr_accessor :layout

    def body
      parse_body_and_frontmatter
      @body
    end

    def frontmatter
      parse_body_and_frontmatter
      @frontmatter
    end

    private

    def parse_body_and_frontmatter
      return if defined?(@frontmatter) && defined?(@body)
      @frontmatter, @body = input_path.read.frontmatter_and_body
    end
  end

  class Layout
    def initialize(input_path:, renderers:)
      self.input_path = input_path
      self.renderers = renderers
    end

    attr_reader :renderers
    attr_reader :input_path

    def body
      @body ||= input_path.read
    end

    private

    attr_writer :input_path
    attr_writer :renderers
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
          compiled_erb =
            Erubi::CaptureEndEngine
            .new(source, bufvar: :@_buf, ensure: true, yield_returns_buffer: true)
            .src

          eval_location =
            if path
              [path.to_s, 0]
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
      def initialize(routes:, layouts:, assets:, contents:, locals:, frontmatter:)
        @routes = routes
        @layouts = layouts
        @assets = assets
        @contents = contents

        @locals = locals
        @frontmatter = frontmatter
      end

      attr_reader :routes
      attr_reader :layouts
      attr_reader :assets
      attr_reader :contents
      attr_reader :locals
      attr_reader :frontmatter

      def capture
        original_buffer = @_buf
        @_buf = +""
        yield
        @_buf
      ensure
        @_buf = original_buffer
      end

      def render(blob, layout: nil, &block)
        render_chain = RenderChain.new(
          body: blob.body,
          path: blob.input_path,
          renderers: blob.renderers,
          view_context: self
        )
        rendered_body =
          if block_given?
            render_chain.call do
              capture { yield }
            end
          else
            render_chain.call
          end

        if layout
          layout_render_chain = RenderChain.new(
            body: layout.body,
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
        compile_assets(site.asset_blobs.send(:lookup))
        compile_contents(site.route_identifiers.send(:lookup).values)
      end
    end

    private

    PARCEL_FILES_OUTPUT_REGEX = /^✨[^\n]+\n\n(.*)Done in(?:.*)\z/m
    PARCEL_FILE_OUTPUT_REGEX = /^(?<page>.*?)\s+(?<size>[0-9\.]+\s*[A-Z]?B)\s+(?<time>[0-9\.]+[a-z]?s)$/

    def compile_assets(asset_files)
      asset_paths = asset_files.values

      if assets_dirty?
        out, status = Open3.capture2(
          "yarn",
          "run",
          "parcel",
          "build",
          "--dist-dir", site.assets_root.to_s,
          "--public-url", site.assets_root.basename.to_s,
          *asset_paths.select(&:entrypoint?).map(&:input_path).map(&:to_s)
        )

        if !status.success?
          raise "Asset compilation failed"
        end

        matches = PARCEL_FILES_OUTPUT_REGEX.match(out)[1]

        if !matches
          raise "Asset compilation output parsing failed"
        end

        processed_file_paths = matches.split("\n\n")

        processed_file_paths.map do |file|
          output_file, input_file = file.strip.split("\n└── ")

          output_path = site.root.concat(output_file[PARCEL_FILE_OUTPUT_REGEX, 1])
          input_path = site.root.concat(input_file[PARCEL_FILE_OUTPUT_REGEX, 1])

          if !asset_files.key?(input_path)
            next
          end

          url_path = output_path.relative_path_from(site.output_root)
          asset_files[input_path].url_path = url_path.to_s
          asset_files[input_path].output_path = output_path
          asset_files[input_path].body = output_path.read
        end
      end
    end

    def compile_content(content)
      view_context = Rendering::ViewContext.new(
        routes: site.route_identifiers,
        layouts: site.layout_blobs,
        assets: site.asset_blobs,
        contents: site.content_blobs,
        locals: content.locals,
        frontmatter: content.frontmatter
      )

      rendered_body = view_context.render(content, layout: content.layout) || ""

      content.output_path =
        if content.url_path[-1] == "/"
          site.output_root.concat(content.url_path, site.config.fetch(:index))
        else
          site.output_root.concat(content.url_path)
        end

      if content.output_path.exist?
        if content.output_path.read == rendered_body
          return
        end
      end

      if !site.output_root.include?(content.output_path)
        return
      end

      if !content.output_path.dirname.directory?
        content.output_path.dirname.mkpath
      end

      content.output_path.write(rendered_body)

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
