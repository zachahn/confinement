# JUST FOR TESTING
lib = File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
# END OF JUST FOR TESTING

require "confinement"

Confinement.root = __dir__

Confinement.site = Confinement::Builder.new(
  root: Confinement.root,
  assets: "assets",
  contents: "contents",
  layouts: "layouts",
  config: {
    index: "index.html"
  }
)
