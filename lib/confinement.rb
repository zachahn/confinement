if Gem.loaded_specs.has_key?("pry-byebug")
  require "pry-byebug"
elsif Gem.loaded_specs.has_key?("pry-byebug")
  require "pry"
end

require "confinement/version"

module Confinement
  class Error < StandardError; end
  # Your code goes here...
end
