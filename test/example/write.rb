require_relative "build"

Confinement::Compiler.new(Confinement.config).compile_everything(Confinement.site)
