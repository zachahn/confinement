require_relative "boot"

Confinement.config = Confinement::Config.new(root: File.dirname(__dir__))

Confinement.config.compiler do |compiler|
  compiler.output_root = "public"
  compiler.output_assets = "assets"
  compiler.output_directory_index = "index.html"
end

Confinement.config.source do |source|
  source.assets = "assets"
  source.contents = "contents"
  source.layouts = "layouts"
end

# Confinement.loader do |loader|
#   # ...
# end

# Confinement.watcher_paths do |paths|
#   # ...
# end
