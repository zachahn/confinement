require_relative "boot"

# Refines `Pathname#frontmatter` and `Pathname#body`
using Confinement::Easier

#  ____
# |  _ \ __ _  __ _  ___  ___
# | |_) / _` |/ _` |/ _ \/ __|
# |  __/ (_| | (_| |  __/\__ \
# |_|   \__,_|\__, |\___||___/
#             |___/
Confinement.site.contents do |contents, layouts, dest|
  dest["/"] = Confinement::Content.new(
    input_path: contents.join("index.html.erb"),
    renderers: [Confinement::Renderer::Erb.new]
  )

  blog_posts = contents.glob("posts/*.md*").filter_map do |blog_post|
    unixtime = blog_post.basename.to_s[/^\d+/]

    next if unixtime.nil?

    dest["/posts/#{unixtime}/"] = Confinement::Content.new(
      input_path: blog_post,
      renderers: [Confinement::Renderer::Erb.new]
    )
  end

  dest["/posts/"] = Confinement::Content.new(
    input_path: contents.join("posts.html.erb"),
    locals: {
      blog_posts: blog_posts
    },
    renderers: [Confinement::Renderer::Erb.new]
  )

  dest["/resume/"] = Confinement::Content.new(
    input_path: contents.join("resume.html.erb"),
    renderers: [Confinement::Renderer::Erb.new]
  )

  dest["/resume.pdf"] = Confinement::Content.new(
    input_path: contents.join("resume.tex.erb"),
    renderers: [Confinement::Renderer::Erb.new]
  )

  dest["/about/"] = Confinement::Content.new(
    input_path: contents.join("about.html.erb"),
    renderers: [Confinement::Renderer::Erb.new]
  )

  dest["/view_with_layout.html"] = Confinement::Content.new(
    layout: layouts.join("default.html.erb"),
    input_path: contents.join("view_with_layout.html.erb"),
    renderers: [Confinement::Renderer::Erb.new]
  )

  dest["/static_view_with_layout.html"] = Confinement::Content.new(
    layout: layouts.join("default.html.erb"),
    input_path: contents.join("static_view_with_layout.html"),
    renderers: []
  )

  dest["/frontmatter.html"] = Confinement::Content.new(
    input_path: contents.join("frontmatter.html.erb"),
    renderers: [Confinement::Renderer::Erb.new]
  )

  dest["/partial.html"] = Confinement::Content.new(
    input_path: contents.join("partial.html.erb"),
    renderers: [Confinement::Renderer::Erb.new]
  )
end

#    _   ___ ___ ___ _____ ___
#   /_\ / __/ __| __|_   _/ __|
#  / _ \\__ \__ \ _|  | | \__ \
# /_/ \_\___/___/___| |_| |___/
#
Confinement.site.assets do |assets, dest|
  dest["/assets/application.js"] = Confinement::Asset.new(
    input_path: assets.join("application.js"),
    entrypoint: true,
  )

  dest["/assets/application.css"] = Confinement::Asset.new(
    input_path: assets.join("application.css"),
    entrypoint: false,
  )
end

Confinement.site.layouts do |layouts, dest|
  dest[layouts.join("default.html.erb")] = Confinement::Layout.new(
    renderers: [Confinement::Renderer::Erb.new]
  )
end
