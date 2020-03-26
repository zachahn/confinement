$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
require "confinement"

require "minitest/autorun"
require "open3"

class TestCase < Minitest::Test
end
