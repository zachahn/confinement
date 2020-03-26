$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
require "confinement"

require "minitest/autorun"

class TestCase < Minitest::Test
end
