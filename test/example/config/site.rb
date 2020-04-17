require_relative "boot"

Confinement.site = Confinement::Site.build do |site|
  site.root = File.dirname(__dir__)
  site.assets = "assets"
  site.contents = "contents"
  site.layouts = "layouts"
  site.output_root = "public"
end
