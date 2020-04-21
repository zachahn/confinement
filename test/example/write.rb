require_relative "build"

Confinement::Compiler.new.compile_everything(Confinement.site)
