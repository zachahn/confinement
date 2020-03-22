require_relative "boot"

# Refines `Pathname#frontmatter` and `Pathname#body`
using Confinement::Easier

#  ____
# |  _ \ __ _  __ _  ___  ___
# | |_) / _` |/ _` |/ _ \/ __|
# |  __/ (_| | (_| |  __/\__ \
# |_|   \__,_|\__, |\___||___/
#             |___/
Confinement.site.contents do |contents, dest|
  dest["/"] = Confinement::Page.new(
    layout: "default",
    source: contents.join("index.html.erb")
  )

  blog_posts = contents.glob("posts/*.md*").filter_map do |blog_post|
    unixtime = blog_post.basename.to_s[/^\d+/]

    next if unixtime.nil?

    dest["/posts/#{unixtime}/"] = Confinement::Page.new(
      layout: "blog_post",
      source: blog_post
    )
  end

  dest["/posts/"] = Confinement::Page.new(
    layout: "default",
    source: contents.join("posts.html.erb"),
    locals: {
      blog_posts: blog_posts
    }
  )

  dest["/resume/"] = Confinement::Page.new(
    layout: "default",
    source: contents.join("resume.html.erb"),
  )

  dest["/resume.pdf"] = Confinement::Page.new(
    layout: "default",
    source: contents.join("resume.tex.erb"),
  )

  dest["/about/"] = Confinement::Page.new(
    layout: "default",
    source: contents.join("about.html.erb"),
  )

  dest["/about/rated/"] = Confinement::Page.new(
    layout: "default",
    source: contents.join("about-rated.html.erb"),
  )
end

#    _   ___ ___ ___ _____ ___
#   /_\ / __/ __| __|_   _/ __|
#  / _ \\__ \__ \ _|  | | \__ \
# /_/ \_\___/___/___| |_| |___/
#
Confinement.site.assets do |assets, dest|
  dest["/assets/application.js"] = Confinement::Asset.new(
    source: assets.join("application.js"),
    entrypoint: true,
  )

  dest["/assets/application.css"] = Confinement::Asset.new(
    source: assets.join("application.css"),
    entrypoint: false,
  )
end
