require "test_helper"

class ConfinementTest < TestCase
  def test_example
    root = Pathname.new(__dir__).join("example")
    compiled = root.join("public")

    Dir.chdir(root) do
      compiled.rmtree if compiled.directory?

      _, status = Open3.capture2("ruby", "write.rb")

      assert_equal(true, status.success?)
      assert_equal(<<~HTML, compiled.join("index.html").read)
        <h1>HOME PAGE</h1>
        /about/
        /posts/
        /resume/
        /resume.pdf
      HTML
      assert_equal(<<~HTML.strip, compiled.join("frontmatter.html").read)
        hello
        {"my_frontmatter"=>"hello"}
      HTML
      assert_equal(<<~HTML, compiled.join("partial.html").read)
        before the partial
        I AM A PARTIAL! 42

        after the partial
      HTML

      assert_equal(<<~JS.strip, compiled.join("assets/application.js").read)
        console.log("JavaScript!");
      JS
      assert_equal(<<~CSS.strip, compiled.join("assets/application.css").read)
        body{color:#00f}
      CSS
    end
  end
end
