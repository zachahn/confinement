# JUST FOR TESTING
lib = File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
# END OF JUST FOR TESTING

require "pry"
require "confinement"

Confinement.site = Confinement::Site.new(
  root: __dir__,
  assets: "assets",
  contents: "contents",
  layouts: "layouts",
  output_root: "public"
)
