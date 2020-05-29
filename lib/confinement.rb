# frozen_string_literal: true

if Gem.loaded_specs.has_key?("pry")
  require "pry"
end

# standard library
require "digest"
require "logger"
require "open3"
require "pathname"
require "yaml"

# gems
require "erubi"
require "erubi/capture_end"
require "zeitwerk"

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

  module BuilderGetterInitialization
    def builder_getter(method_name, klass, ivar, new: [])
      init_parameters = [*new, "&block"].join(", ")

      class_eval(<<~RUBY, __FILE__, __LINE__)
        def #{method_name}(&block)
          if #{ivar}
            if block_given?
              raise "#{method_name} is already set up"
            end

            return #{ivar}
          end

          if !block_given?
            raise "Can't initialize #{method_name} without block"
          end

          #{ivar} = #{klass}.new(#{init_parameters})
          #{ivar}
        end
      RUBY
    end
  end

  class << self
    extend BuilderGetterInitialization

    attr_accessor :config
    attr_accessor :site
    attr_writer :env

    def env
      @env ||= ENV.fetch("CONFINEMENT_ENV", "development")
    end
  end

  class Config
    extend BuilderGetterInitialization

    builder_getter("loader", "ZeitwerkProxy", "@loader")
    builder_getter("watcher", "WatcherPaths", "@watcher", new: ["root: @root"])
    builder_getter("compiler", "Config::Compiler", "@compiler", new: ["root: @root"])
    builder_getter("source", "Config::Source", "@source", new: ["root: @root"])

    def initialize(root:)
      @root = Pathname.new(root).expand_path.cleanpath

      if !@root.exist?
        raise Error::PathDoesNotExist, "Root path does not exist: #{@root}"
      end
    end

    attr_reader :root
    attr_writer :logger

    def logger
      @logger ||= default_logger
    end

    def default_logger
      Logger.new($stdout).tap do |l|
        l.level = Logger::INFO
      end
    end

    class ZeitwerkProxy
      def initialize
        @loader = Zeitwerk::Loader.new
        yield(self)
        @loader.setup
      end

      def push_dir(dir)
        @loader.push_dir(dir)
      end

      def enable_reloading
        @loader.enable_reloading
      end

      def reload
        @loader.reload
      end
    end

    class WatcherPaths
      def initialize(root:)
        @root = root
        @assets = []
        @contents = []

        yield(self)

        @assets = @assets.map { |path| @root.concat(path) }
        @contents = @contents.map { |path| @root.concat(path) }
      end

      attr_reader :assets
      attr_reader :contents
    end

    class Compiler
      def initialize(root:)
        @root = root
        self.parcel_cache = false
        self.parcel_cache_directory = "tmp/parcel"

        yield(self)

        self.output_root ||= default_output_root
      end

      attr_accessor :output_root
      attr_accessor :output_assets
      attr_accessor :output_directory_index
      attr_accessor :parcel_cache
      attr_accessor :parcel_cache_directory
      attr_accessor :parcel_minify

      def output_root_path
        @root.concat(output_root).cleanpath.expand_path
      end

      def output_assets_path
        @root.concat(output_root, output_assets).cleanpath.expand_path
      end

      def parcel_cache_directory_path
        if parcel_cache_directory
          @root.concat(parcel_cache_directory).cleanpath.expand_path
        end
      end

      def default_output_root
        "tmp/build-#{Confinement.env}"
      end
    end

    class Source
      def initialize(root:)
        @root = root
        yield(self)
      end

      attr_accessor :assets
      attr_accessor :contents
      attr_accessor :layouts

      def assets_path
        @root.concat(assets).cleanpath.expand_path
      end

      def contents_path
        @root.concat(contents).cleanpath.expand_path
      end

      def layouts_path
        @root.concat(layouts).cleanpath.expand_path
      end
    end
  end

  class Site
    def initialize(config)
      @root = config.root

      yield(self)

      @view_context_helpers ||= []
      @guesses ||= Rendering.guesses

      @route_identifiers = RouteIdentifiers.new
      @asset_blobs = Blobs.new(scoped_root: config.source.assets_path, file_abstraction_class: Asset)
      @content_blobs = Blobs.new(scoped_root: config.source.contents_path, file_abstraction_class: Content)
      @layout_blobs = Blobs.new(scoped_root: config.source.layouts_path, file_abstraction_class: Layout)
    end

    attr_reader :root

    attr_reader :route_identifiers
    attr_reader :asset_blobs
    attr_reader :content_blobs
    attr_reader :layout_blobs

    attr_accessor :view_context_helpers
    attr_accessor :guesses

    def rules
      yield(
        assets: @asset_blobs,
        layouts: @layout_blobs,
        contents: @content_blobs,
        routes: @route_identifiers
      )

      guesser = Rendering::Guesser.new(guesses)
      guess_renderers(guesser, @layout_blobs)
      guess_renderers(guesser, @content_blobs)

      @asset_blobs.done!
      @layout_blobs.done!
      @content_blobs.done!
      @route_identifiers.done!

      nil
    end

    def partial_compilation
      { asset_blobs: @asset_blobs }
    end

    def partial_compilation=(previous_partial_compilation)
      return if previous_partial_compilation.nil?

      @asset_blobs = previous_partial_compilation.fetch(:asset_blobs)

      nil
    end

    private

    def guess_renderers(guesser, blobs)
      blobs.send(:lookup).values.each do |blob|
        blob.renderers = blob.renderers.flat_map do |renderer|
          if renderer == :guess
            guesser.call(blob.input_path)
          else
            renderer
          end
        end
      end
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
  end

  module RouteableBlob
    attr_accessor :output_path
    attr_reader :url_path

    def url_path=(new_url_path)
      @url_path = new_url_path.normalize_for_route
    end
  end

  module RenderableBlob
    attr_reader :renderers

    def renderers=(new_renderers)
      @renderers = Array(new_renderers)
    end
  end

  class Asset
    include Blob
    include RouteableBlob

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
    include RouteableBlob
    include RenderableBlob

    def initialize(input_path:, layout: nil, locals: {}, renderers: :guess)
      self.input_path = input_path

      self.layout = layout
      self.locals = locals
      self.renderers = renderers
    end

    attr_accessor :locals
    attr_accessor :layout

    def body
      parse_body_and_frontmatter
      @body
    end

    def frontmatter
      parse_body_and_frontmatter
      @frontmatter
    end

    def input
      frontmatter.merge(locals)
    end

    private

    def parse_body_and_frontmatter
      return if defined?(@frontmatter) && defined?(@body)
      @frontmatter, @body = input_path.read.frontmatter_and_body
    end
  end

  class Layout
    include Blob
    include RenderableBlob

    def initialize(input_path:, renderers: :guess)
      self.input_path = input_path
      self.renderers = renderers
    end

    def body
      @body ||= input_path.read
    end
  end

  class Renderer
    def self.guesses
      @guesses ||= {
        "erb" => -> { Erb.new }
      }
    end

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
    class Guesser
      def initialize(guessing_registry)
        @guessing_registry = guessing_registry
      end

      def call(path)
        basename = path.basename.to_s
        extensions = basename.split(".")[1..-1]

        extensions.reverse.filter_map do |extension|
          next if !@guessing_registry.key?(extension)

          guess = @guessing_registry[extension]
          guess = guess.call if guess.is_a?(Proc)

          guess
        end
      end
    end

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

      def input
        frontmatter.merge(locals)
      end

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

  class Compiler
    def initialize(config)
      @config = config
      @logger = config.logger
    end

    def compile_everything(site)
      # Assets first since it's almost always a dependency of contents
      compile_assets(site)
      compile_contents(site)
    end

    PARCEL_FILES_OUTPUT_REGEX = /^✨[^\n]+\n\n(.*)Done in(?:.*)\z/m
    PARCEL_FILE_OUTPUT_REGEX = /^(?<page>.*?)\s+(?<size>[0-9\.]+\s*[A-Z]?B)\s+(?<time>[0-9\.]+[a-z]?s)$/

    def compile_assets(site)
      @logger.info { "compiling assets" }
      create_destination_directory
      asset_files = site.asset_blobs.send(:lookup)
      asset_paths = asset_files.values

      command = [
        "yarn",
        "run",
        "parcel",
        "build",
      ]

      if !@config.compiler.parcel_minify
        command.push("--no-minify")
      end

      if @config.compiler.parcel_cache && @config.compiler.parcel_cache_directory
        command.push("--cache-dir", @config.compiler.parcel_cache_directory_path.to_s)
      else
        command.push("--no-cache")
      end

      command.push("--dist-dir", @config.compiler.output_assets_path.to_s)
      command.push("--public-url", @config.compiler.output_assets_path.basename.to_s)
      command.push(*asset_paths.select(&:entrypoint?).map(&:input_path).map(&:to_s))

      @logger.debug { "running: #{command.join(" ")}" }

      out, status = Open3.capture2(*command)

      if !status.success?
        @logger.fatal { "asset compilation failed" }
        raise "Asset compilation failed"
      end

      matches = PARCEL_FILES_OUTPUT_REGEX.match(out)[1]

      if !matches
        @logger.fatal { "asset compilation ouptut parsing failed" }
        raise "Asset compilation output parsing failed"
      end

      processed_file_paths = matches.split("\n\n")

      processed_file_paths.map do |file|
        output_file, *input_files = file.strip.split(/\n(?:└|├)── /)

        output_path = @config.root.concat(output_file[PARCEL_FILE_OUTPUT_REGEX, 1])

        input_files.each do |input_file|
          input_path = @config.root.concat(input_file[PARCEL_FILE_OUTPUT_REGEX, 1])

          if !asset_files.key?(input_path)
            next
          end

          url_path = output_path.relative_path_from(@config.compiler.output_root_path)
          @logger.debug { "processesd asset: #{input_path}, #{url_path}, #{output_path}" }
          asset_files[input_path].url_path = url_path.to_s
          asset_files[input_path].output_path = output_path
          asset_files[input_path].body = output_path.read
        end
      end

      @logger.info { "finished compiling assets" }
    end

    def compile_contents(site)
      @logger.info { "compiling contents" }
      create_destination_directory
      contents = site.route_identifiers.send(:lookup).values
      contents.each do |content|
        compile_content(site, content)
      end
      @logger.info { "finished compiling contents" }
    end

    def partial_compilation_dirty?(before:, after:)
      return true if !before.key?(:asset_blobs)
      return true if !after.key?(:asset_blobs)

      before_assets = before[:asset_blobs].send(:lookup)
      after_assets = after[:asset_blobs].send(:lookup)

      return true if before_assets.keys.sort != after_assets.keys.sort
      return true if before_assets.any? { |k, v| v.input_path != after_assets[k].input_path }
      return true if before_assets.any? { |k, v| v.entrypoint? != after_assets[k].entrypoint? }

      false
    end

    private

    def create_destination_directory
      destination = @config.compiler.output_root_path

      if destination.exist?
        return
      end

      if !destination.dirname.exist?
        raise Error::PathDoesNotExist, "Destination's parent path does not exist: #{destination.dirname}"
      end

      destination.mkpath
    end

    def compile_content(site, content)
      @logger.debug { "compiling content: #{content.input_path}, #{content.renderers}" }
      view_context = Rendering::ViewContext.new(
        routes: site.route_identifiers,
        layouts: site.layout_blobs,
        assets: site.asset_blobs,
        contents: site.content_blobs,
        locals: content.locals,
        frontmatter: content.frontmatter
      )

      site.view_context_helpers.each do |helper|
        view_context.extend(helper)
      end

      rendered_body = view_context.render(content, layout: content.layout) || ""

      content.output_path =
        if content.url_path[-1] == "/"
          @config.compiler.output_root_path.concat(content.url_path, @config.compiler.output_directory_index)
        else
          @config.compiler.output_root_path.concat(content.url_path)
        end

      if content.output_path.exist?
        if content.output_path.read == rendered_body
          return
        end
      end

      if !@config.compiler.output_root_path.include?(content.output_path)
        return
      end

      if !content.output_path.dirname.directory?
        content.output_path.dirname.mkpath
      end

      content.output_path.write(rendered_body)

      nil
    end
  end
end
