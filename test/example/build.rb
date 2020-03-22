require_relative "boot"

# Refines `Pathname#frontmatter` and `Pathname#body`
using Confinement::Easier

Confinement.site.build do |source, dest|
  dest["/"] = Confinement::Page.new(
    layout: "default",
    source: source.join("index.html.erb")
  )

  blog_posts = source.glob("posts/*.md*").filter_map do |blog_post|
    unixtime = blog_post.path.basename[/^\d+/]

    next if unixtime.nil?

    dest["/posts/#{unixtime}/"] = Confinement::Page.new(
      layout: "blog_post",
      source: blog_post
    )
  end

  dest["/posts/"] = Confinement::Page.new(
    layout: "default",
    source: source.join("posts.html.erb"),
    locals: {
      blog_posts: blog_posts
    }
  )

  dest["/resume/"] = Confinement::Page.new(
    layout: "default",
    source: source.join("resume.html.erb"),
  )

  dest["/resume.pdf"] = Confinement::Page.new(
    layout: "default",
    source: source.join("resume.tex.erb"),
  )

  dest["/about/"] = Confinement::Page.new(
    layout: "default",
    source: source.join("about.html.erb"),
  )

  dest["/about/rated/"] = Confinement::Page.new(
    layout: "default",
    source: source.join("about-rated.html.erb"),
  )

  #    _   ___ ___ ___ _____ ___
  #   /_\ / __/ __| __|_   _/ __|
  #  / _ \\__ \__ \ _|  | | \__ \
  # /_/ \_\___/___/___| |_| |___/
  #
  # Bit of a blocker: https://github.com/parcel-bundler/parcel/issues/4200
  #
  # MY BIG QUESTION is how to handle assets.
  # `dest`'s keys is supposed to be the path
  dest.parcel["/assets/application.js"] = Confinement::Asset.new(
    source: source.join("assets/application.js"),
    entrypoint: true,
  )

  dest.parcel["/assets/application.css"] = Confinement::Asset.new(
    source: source.join("assets/application.css"),
    entrypoint: false,
  )
end
