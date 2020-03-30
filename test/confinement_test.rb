require "test_helper"

class ConfinementTest < TestCase
  def test_example
    root = Pathname.new(__dir__).join("example")
    compiled = root.join("public")

    Dir.chdir(root) do
      compiled.rmtree if compiled.directory?

      stdout, status = Open3.capture2("ruby", "write.rb")

      if !status.success?
        puts stdout
      end

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
        {:my_frontmatter=>"hello"}
      HTML
      assert_equal(<<~HTML, compiled.join("partial.html").read)
        before the partial
        I AM A PARTIAL! 42

        after the partial
      HTML
      assert_equal(<<~HTML, compiled.join("view_with_layout.html").read)
        <html>
        <head>
        <title>integration test!</title>
        <link rel="stylesheet" type="text/css" href="/assets/application.css">
        <script type="text/javascript" src="/assets/application.js"></script>
        </head>
        <body>
        Before this is the layout
        This part is the rendered ERB file
        After this is the layout

        </body>
        </html>
      HTML
      assert_equal(<<~HTML, compiled.join("static_view_with_layout.html").read)
        <html>
        <head>
        <title>integration test!</title>
        <link rel="stylesheet" type="text/css" href="/assets/application.css">
        <script type="text/javascript" src="/assets/application.js"></script>
        </head>
        <body>
        I am just a html page

        </body>
        </html>
      HTML
      assert_equal(<<~HTML, compiled.join("view_with_embedded_asset.html").read)
        <style>
        body{color:#00f}
        </style>
      HTML
      assert_equal("very kewl", compiled.join("view_with_local_and_frontmatter_cooperation.html").read)

      assert_equal(<<~JS.strip, compiled.join("assets/application.js").read)
        console.log("JavaScript!");
      JS
      assert_equal(<<~CSS.strip, compiled.join("assets/application.css").read)
        body{color:#00f}
      CSS
    end
  end
end
