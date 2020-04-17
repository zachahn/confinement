# JUST FOR TESTING
lib = File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
# END OF JUST FOR TESTING

require "pry"
require "confinement"

Confinement.site = Confinement::Site.build do |site|
  site.root = __dir__
  site.assets = "assets"
  site.contents = "contents"
  site.layouts = "layouts"
  site.output_root = "public"
end
