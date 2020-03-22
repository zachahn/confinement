require_relative "build"

Confinement::Publish
  .new(Confinement.site)
  .write(Confinement.root.join("public"))
