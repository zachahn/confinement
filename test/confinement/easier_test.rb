require "test_helper"

class EasierTest < TestCase
  using Confinement::Easier

  def test_pathname_concat
    assert_equal(Pathname.new("/foo/bar"), Pathname.new("/foo").concat("/bar"))
    assert_equal(Pathname.new("/foo/bar"), Pathname.new("/foo/").concat("/bar"))
  end

  def test_pathname_include?
    assert_equal(true, Pathname.new("/foo").include?(Pathname.new("/foo/bar")))
    assert_equal(true, Pathname.new("/foo").include?(Pathname.new("/foo/bar/baz")))
    assert_equal(true, Pathname.new("/foo").include?(Pathname.new("/foo")))

    assert_equal(false, Pathname.new("/foo").include?(Pathname.new("/")))
    assert_equal(false, Pathname.new("/foo").include?(Pathname.new("/bar")))
  end

  def test_string_frontmatter_and_body
    assert_equal([{}, "\xf0\x28\x8c\x28"], "\xf0\x28\x8c\x28".frontmatter_and_body)
    assert_equal([{}, "\ntesting\n"], "\ntesting\n".frontmatter_and_body)

    assert_equal([{ "hello" => "world" }, "testing"], <<~TEST.frontmatter_and_body)
      ---
      hello: world
      ---

      testing
    TEST

    assert_equal([{ "hello" => "world" }, "\ntesting\n"], <<~TEST.frontmatter_and_body(strip: false))
      ---
      hello: world
      ---

      testing
    TEST
  end
end
